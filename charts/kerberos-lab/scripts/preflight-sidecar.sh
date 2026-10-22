#!/usr/bin/env bash
# Fail closed before demo/support review: keytab Secret, proxy URL, sidecar container, Negotiate smoke.
set -euo pipefail
NS_HUB="${NS_HUB:-rhdh-kerberos}"
NS_LAB="${NS_LAB:-kerberos-lab}"
SECRET="${SECRET:-kerberos-bridge-keytab}"
TARGET="${TARGET:-https://example.com}"

need() { command -v "$1" >/dev/null || { echo "missing $1" >&2; exit 1; }; }
need oc
fail=0

echo "==> Hub Secret ${SECRET}"
if oc -n "$NS_HUB" get secret "$SECRET" >/dev/null 2>&1; then
  echo "OK  secret exists"
else
  echo "FAIL secret ${NS_HUB}/${SECRET} missing (run keytab sync Job or sync-bridge-keytab-secret.sh)"
  fail=$((fail + 1))
fi

echo "==> HTTP_PROXY must be localhost sidecar"
PROXY="$(oc -n "$NS_HUB" get secret rhdh-kerberos-secrets -o jsonpath='{.data.HTTP_PROXY}' 2>/dev/null | base64 -d || true)"
if [[ "$PROXY" == "http://127.0.0.1:3128" || "$PROXY" == "http://localhost:3128" ]]; then
  echo "OK  HTTP_PROXY=$PROXY"
else
  echo "FAIL HTTP_PROXY='$PROXY' (want http://127.0.0.1:3128)"
  fail=$((fail + 1))
fi

echo "==> lab stack"
for d in kdc corporate-proxy; do
  if oc -n "$NS_LAB" get deploy "$d" >/dev/null 2>&1; then
    oc -n "$NS_LAB" rollout status "deploy/$d" --timeout=60s >/dev/null && echo "OK  $d Ready" || { echo "FAIL $d not Ready"; fail=$((fail + 1)); }
  else
    echo "FAIL deploy/$d missing in $NS_LAB"
    fail=$((fail + 1))
  fi
done

echo "==> Hub pod sidecar"
POD="$(oc -n "$NS_HUB" get pods -l app.kubernetes.io/name=backstage --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -z "$POD" ]]; then
  echo "FAIL no Running Hub pod"
  fail=$((fail + 1))
else
  CS="$(oc -n "$NS_HUB" get pod "$POD" -o jsonpath='{.spec.containers[*].name}')"
  echo "    pod=$POD containers=$CS"
  echo "$CS" | grep -qw kerberos-bridge && echo "OK  kerberos-bridge present" || { echo "FAIL kerberos-bridge missing"; fail=$((fail + 1)); }
  BIND="$(oc -n "$NS_HUB" exec "$POD" -c kerberos-bridge -- grep http_port /tmp/squid.conf 2>/dev/null || true)"
  echo "$BIND" | grep -q '127.0.0.1:3128' && echo "OK  loopback bind" || { echo "FAIL squid not on 127.0.0.1 ($BIND)"; fail=$((fail + 1)); }
  if oc -n "$NS_HUB" exec "$POD" -c kerberos-bridge -- /healthcheck.sh 3128 >/dev/null 2>&1; then
    echo "OK  healthcheck (squid + klist)"
  else
    echo "FAIL healthcheck.sh (squid down or TGT missing)"
    fail=$((fail + 1))
  fi
  if oc -n "$NS_HUB" exec "$POD" -c backstage-backend -- \
      sh -c "node --use-env-proxy -e \"fetch('${TARGET}').then(r=>{console.log(r.status); if(r.status!==200) process.exit(2)}).catch(e=>{console.error(e); process.exit(1)})\"" \
      >/tmp/preflight-fetch.out 2>&1; then
    echo "OK  Negotiate fetch $(cat /tmp/preflight-fetch.out | tr -d '\n')"
  else
    echo "FAIL Negotiate fetch"; cat /tmp/preflight-fetch.out >&2 || true
    fail=$((fail + 1))
  fi
fi

if [[ "$fail" -gt 0 ]]; then
  echo "RESULT: $fail failure(s) — not demo-ready"
  exit 1
fi
echo "RESULT: OK — sidecar path ready for demo"
