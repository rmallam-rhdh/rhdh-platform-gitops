#!/usr/bin/env bash
# Checks the gateway-cert-lab deployment on a live cluster. Read-only, except:
#   --renew  forces a renewal of the first host's certificate (cert-manager reissues it)
#   --limit  sends a 65-listener Gateway to the API as a server-side dry run (nothing is created)
# Usage: [CONTEXT=<oc context>] charts/gateway-cert-lab/tests/verify.sh [--renew] [--limit]
set -uo pipefail

OC="oc${CONTEXT:+ --context=$CONTEXT}"
GW_NS="${GW_NS:-gwcert-ingress}"
GW="${GW:-shared-gw}"
INTRUDER_NS="${INTRUDER_NS:-gwcert-intruder}"
SCALE_GW="${SCALE_GW:-scale-gw}"
CA_SECRET="${CA_SECRET:-stand-in-ca}"
RENEW=false; LIMIT=false
for a in "$@"; do case "$a" in --renew) RENEW=true ;; --limit) LIMIT=true ;; *) echo "unknown option $a"; exit 2 ;; esac; done

pass=0; fail=0
ok()  { echo "PASS  $*"; pass=$((pass+1)); }
bad() { echo "FAIL  $*"; fail=$((fail+1)); }
info(){ echo "      $*"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
$OC get secret "$CA_SECRET" -n "$GW_NS" -o jsonpath='{.data.ca\.crt}' | base64 -d > "$TMP/ca.crt" 2>/dev/null
[ -s "$TMP/ca.crt" ] || { echo "Cannot read CA secret $GW_NS/$CA_SECRET. Is the app synced?"; exit 1; }

served() { # host -> "serial pubkey-hash"
  echo | openssl s_client -connect "$1:443" -servername "$1" 2>/dev/null > "$TMP/s.pem"
  local s k
  s=$(openssl x509 -in "$TMP/s.pem" -noout -serial 2>/dev/null | cut -d= -f2)
  k=$(openssl x509 -in "$TMP/s.pem" -noout -pubkey 2>/dev/null | openssl sha256 | awk '{print $NF}' | cut -c1-16)
  echo "$s $k"
}
gwpod() { $OC get pods -n "$GW_NS" -l gateway.networking.k8s.io/gateway-name="$1" -o jsonpath='{.items[0].metadata.name}/{.items[0].status.containerStatuses[0].restartCount}'; }

echo "== 1. Listeners on $GW_NS/$GW"
$OC get gateway "$GW" -n "$GW_NS" -o jsonpath='{range .status.listeners[*]}{.name} {range .conditions[?(@.type=="Programmed")]}{.status}{end} {range .conditions[?(@.type=="ResolvedRefs")]}{.reason}{end}{"\n"}{end}' > "$TMP/listeners"
while read -r name prog reason; do
  [ -z "$name" ] && continue
  if [ "$prog" = True ]; then ok "listener $name Programmed"
  elif [ "$reason" = InvalidCertificateRef ]; then info "listener $name not Programmed ($reason): expected only when brokenHost is enabled"; echo "$name" >> "$TMP/broken"
  else bad "listener $name not Programmed ($reason)"; fi
done < "$TMP/listeners"

echo "== 2. Each host serves its own certificate through the Router"
HOSTS=$($OC get route -n "$GW_NS" -o jsonpath='{range .items[?(@.spec.tls.termination=="passthrough")]}{.spec.host}{"\n"}{end}')
for h in $HOSTS; do
  body=$(curl -sS --max-time 10 --cacert "$TMP/ca.crt" "https://$h/" -w ' HTTP%{http_code}' 2>&1 | tr -d '\n')
  san=$(echo | openssl s_client -connect "$h:443" -servername "$h" 2>/dev/null | openssl x509 -noout -ext subjectAltName 2>/dev/null | grep -o 'DNS:[^, ]*' | tr '\n' ' ')
  if [[ "$body" == *HTTP200 ]] && [ "$san" = "DNS:$h " ]; then ok "$h -> ${body% HTTP200}; certificate names only $h"
  else bad "$h -> $body; SAN: $san"; fi
done

echo "== 3. Hostname hijack from another namespace"
if $OC get httproute -n "$INTRUDER_NS" >/dev/null 2>&1 && [ -n "$($OC get httproute -n "$INTRUDER_NS" -o name)" ]; then
  r=$($OC get httproute -n "$INTRUDER_NS" -o jsonpath='{.items[0].status.parents[0].conditions[?(@.type=="Accepted")].reason}')
  [ "$r" = NotAllowedByListeners ] && ok "intruder HTTPRoute refused: $r" || bad "intruder HTTPRoute: $r"
else info "hijackTest disabled; skipped"; fi

echo "== 4. No SNI, or SNI with no listener, straight to the gateway Service"
IP=$($OC get svc "$GW-istio" -n "$GW_NS" -o jsonpath='{.spec.clusterIP}')
FIRST=$($OC get gateway "$GW" -n "$GW_NS" -o jsonpath='{.spec.listeners[0].hostname}'); DOMAIN="${FIRST#*.}"
out=$($OC run sni-probe-$$ -n "$INTRUDER_NS" --rm -i --restart=Never --quiet --image=registry.access.redhat.com/ubi9/ubi -- bash -c "
  curl -sk -o /dev/null https://$IP/; echo nosni=\$?
  curl -sk -o /dev/null --resolve nobody.$DOMAIN:443:$IP https://nobody.$DOMAIN/; echo unknown=\$?
  curl -sk -o /dev/null -w '%{http_code}' --resolve $FIRST:443:$IP https://$FIRST/; echo ' known'" 2>/dev/null)
echo "$out" | grep -q 'nosni=35' && ok "no SNI: handshake refused" || bad "no SNI: $out"
echo "$out" | grep -q 'unknown=35' && ok "unknown SNI: handshake refused" || bad "unknown SNI: $out"
echo "$out" | grep -q '200 known' && ok "known SNI in cluster: HTTP 200" || bad "known SNI: $out"

echo "== 5. Gateway to app pod over the mesh (HBONE, STRICT)"
APP_NS=$($OC get gateway "$GW" -n "$GW_NS" -o jsonpath='{.spec.listeners[0].allowedRoutes.namespaces.selector.matchLabels.kubernetes\.io/metadata\.name}')
if [ -n "$APP_NS" ]; then
  curl -s -o /dev/null --cacert "$TMP/ca.crt" "https://$FIRST/"; sleep 3
  NODE=$($OC get pods -n "$APP_NS" -o jsonpath='{.items[0].spec.nodeName}')
  ZT=$($OC get pods -n ztunnel -o jsonpath="{range .items[?(@.spec.nodeName==\"$NODE\")]}{.metadata.name}{end}")
  line=$($OC logs -n ztunnel "$ZT" --since=60s 2>/dev/null | grep "ns/$GW_NS/sa/$GW-istio" | grep "dst.namespace=\"$APP_NS\"" | tail -1)
  [[ "$line" == *":15008"* ]] && ok "ztunnel saw gateway identity -> $APP_NS on port 15008" || bad "no HBONE hop seen in ztunnel $ZT for $APP_NS"
else info "no attached app route; skipped"; fi

if $RENEW; then
  echo "== 6. Forced renewal of the first host's certificate"
  CERT=$($OC get certificate -n "$GW_NS" -o jsonpath='{range .items[*]}{.metadata.name} {.spec.dnsNames[0]}{"\n"}{end}' | awk -v h="$FIRST" '$2==h{print $1}')
  OTHER=$(echo "$HOSTS" | grep -v -x "$FIRST" | head -1)
  b1=$(served "$FIRST"); b2=$([ -n "$OTHER" ] && served "$OTHER"); p1=$(gwpod "$GW")
  $OC patch certificate "$CERT" -n "$GW_NS" --subresource=status --type=json \
    -p "[{\"op\":\"add\",\"path\":\"/status/conditions/-\",\"value\":{\"type\":\"Issuing\",\"status\":\"True\",\"reason\":\"ManuallyTriggered\",\"message\":\"verify.sh renewal\",\"lastTransitionTime\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}}]" >/dev/null
  for i in $(seq 1 30); do sleep 3; a1=$(served "$FIRST"); [ "${a1%% *}" != "${b1%% *}" ] && break; done
  a2=$([ -n "$OTHER" ] && served "$OTHER"); p2=$(gwpod "$GW")
  info "before $b1 | after $a1 (about $((i*3)) s)"
  [ "${a1%% *}" != "${b1%% *}" ] && ok "new serial served" || bad "serial unchanged"
  [ "${a1##* }" != "${b1##* }" ] && ok "new private key" || bad "key unchanged"
  [ "$p1" = "$p2" ] && ok "gateway pod not restarted ($p2)" || bad "gateway pod changed $p1 -> $p2"
  [ "$a2" = "$b2" ] && ok "other host untouched" || bad "other host changed"
fi

if [ -s "$TMP/broken" ]; then
  echo "== 7. Broken certificate stays with its own host"
  [ -n "$HOSTS" ] && [ "$fail" -eq 0 ] && ok "$(cat "$TMP/broken") is down while every other host serves" || bad "other hosts affected"
fi

if $LIMIT; then
  echo "== 8. Listener limit (server-side dry run)"
  { echo "apiVersion: gateway.networking.k8s.io/v1"; echo "kind: Gateway"; echo "metadata: {name: limit-test, namespace: $GW_NS}"; echo "spec:"; echo "  gatewayClassName: istio"; echo "  listeners:"
    for i in $(seq -w 1 65); do echo "  - {name: l$i, hostname: l$i.$DOMAIN, port: 443, protocol: HTTPS, tls: {mode: Terminate, certificateRefs: [{name: x}]}}"; done; } > "$TMP/65.yaml"
  res=$($OC apply --dry-run=server -f "$TMP/65.yaml" 2>&1)
  [[ "$res" == *"must have at most 64 items"* ]] && ok "65 listeners rejected (at most 64)" || bad "65 listeners not rejected: $res"
  sed '/name: l65,/d' "$TMP/65.yaml" | $OC apply --dry-run=server -f - >/dev/null 2>&1 && ok "64 listeners accepted" || bad "64 listeners refused"
fi

if $OC get gateway "$SCALE_GW" -n "$GW_NS" >/dev/null 2>&1; then
  echo "== 9. Scale gateway $SCALE_GW"
  want=$($OC get gateway "$SCALE_GW" -n "$GW_NS" -o jsonpath='{range .spec.listeners[*]}x{end}' | wc -c | tr -d ' ')
  got=$($OC get gateway "$SCALE_GW" -n "$GW_NS" -o jsonpath='{range .status.listeners[*]}{range .conditions[?(@.type=="Programmed")]}{.status}{"\n"}{end}{end}' | grep -c True)
  [ "$want" = "$got" ] && ok "$got of $want listeners Programmed" || bad "$got of $want listeners Programmed"
  info "memory: $($OC adm top pod -n "$GW_NS" --no-headers 2>/dev/null | awk '{printf "%s=%s ", $1, $3}')"
fi

echo; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
