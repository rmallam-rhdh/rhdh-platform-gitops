#!/usr/bin/env bash
# Unit: helm lint + template. System: rendered objects include KDC, proxies, NP.
set -euo pipefail
CHART="$(cd "$(dirname "$0")/.." && pwd)"
need() { command -v "$1" >/dev/null || { echo "missing $1" >&2; exit 1; }; }
need helm

fail=0
helm lint "$CHART"

OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT
helm template kerberos-lab "$CHART" -f "$CHART/values.yaml" >"$OUT"

for pat in \
  "kind: Namespace" \
  "name: kerberos-lab" \
  "kind: PersistentVolumeClaim" \
  "name: kdc" \
  "name: corporate-proxy" \
  "app.kubernetes.io/component: kdc" \
  "app.kubernetes.io/component: corporate-proxy" \
  "kind: NetworkPolicy" \
  "rhdh-kerberos" \
  "REALM" \
  "LAB.LOCAL" \
  "system:openshift:scc:anyuid" \
  "serviceAccountName: kerberos-lab" \
  "name: keytab-sync" \
  "bridge-client.keytab"
do
  if grep -q "$pat" "$OUT"; then
    echo "OK  $pat"
  else
    echo "FAIL missing $pat"
    fail=$((fail + 1))
  fi
done

# Default: standalone bridge off (sidecar-first).
if awk '/^kind: Deployment$/{d=1} d&&/^---$/{d=0} d&&/name: bridge$/{found=1} END{exit !found}' "$OUT"; then
  echo "FAIL default values must disable standalone bridge Deployment"
  fail=$((fail + 1))
else
  echo "OK  default has no standalone bridge Deployment"
fi

# Opt-in standalone still renders.
BRIDGE_OUT="$(mktemp)"
helm template kerberos-lab "$CHART" -f "$CHART/values.yaml" --set bridge.enabled=true >"$BRIDGE_OUT"
if grep -q "app.kubernetes.io/component: bridge" "$BRIDGE_OUT"; then
  echo "OK  bridge.enabled=true renders standalone bridge"
else
  echo "FAIL bridge.enabled=true missing bridge"
  fail=$((fail + 1))
fi

# Cluster overlay: standalone bridge off; corporate NP still allows Hub ns.
DEPLOY_OUT="$(mktemp)"
helm template kerberos-lab "$CHART" \
  -f "$CHART/values.yaml" \
  -f "$CHART/values-deploy.yaml" >"$DEPLOY_OUT"
if awk '/^kind: Deployment$/{d=1} d&&/^---$/{d=0} d&&/name: bridge$/{found=1} END{exit !found}' "$DEPLOY_OUT"; then
  echo "FAIL values-deploy must disable standalone bridge Deployment"
  fail=$((fail + 1))
else
  echo "OK  values-deploy has no standalone bridge Deployment"
fi
if grep -q "rhdh-kerberos" "$DEPLOY_OUT"; then
  echo "OK  corporate NP allows rhdh-kerberos (sidecar)"
else
  echo "FAIL deploy render missing rhdh-kerberos on NP"
  fail=$((fail + 1))
fi

# Images and scripts exist
for f in \
  "$CHART/images/kdc/Containerfile" \
  "$CHART/images/corporate-proxy/Containerfile" \
  "$CHART/images/bridge/Containerfile" \
  "$CHART/images/bridge-ubi/Containerfile" \
  "$CHART/images/bridge-ubi/entrypoint.sh" \
  "$CHART/images/bridge-ubi/healthcheck.sh" \
  "$CHART/scripts/build-images.sh" \
  "$CHART/scripts/sync-bridge-keytab-secret.sh" \
  "$CHART/scripts/preflight-sidecar.sh" \
  "$CHART/SIDECAR.md"
do
  if [[ -f "$f" ]]; then
    echo "OK  file $f"
  else
    echo "FAIL missing $f"
    fail=$((fail + 1))
  fi
done
if grep -q 'rhel9/squid' "$CHART/images/bridge-ubi/Containerfile"; then
  echo "OK  bridge-ubi FROM rhel9/squid"
else
  echo "FAIL bridge-ubi must use registry.redhat.io/rhel9/squid"
  fail=$((fail + 1))
fi
if grep -q 'http_port 127.0.0.1:3128' "$CHART/images/bridge-ubi/squid.conf.template"; then
  echo "OK  bridge binds loopback only"
else
  echo "FAIL bridge must use http_port 127.0.0.1:3128 (open-proxy risk)"
  fail=$((fail + 1))
fi
if grep -q 'http_port 3128$' "$CHART/images/bridge-ubi/squid.conf.template"; then
  echo "FAIL bridge must not bind all interfaces"
  fail=$((fail + 1))
fi
if grep -q 'klist -s' "$CHART/images/bridge-ubi/healthcheck.sh"; then
  echo "OK  healthcheck requires Kerberos TGT"
else
  echo "FAIL healthcheck must run klist -s"
  fail=$((fail + 1))
fi
for pat in \
  "login=NEGOTIATE" \
  "127.0.0.1:3128" \
  "bridge-client.keytab" \
  "HTTP/" \
  "kerberos-bridge" \
  "CORPORATE_PROXY_HOSTNAME" \
  "open forward proxy" \
  "not a supported RHDH"
do
  if grep -qi "$pat" "$CHART/SIDECAR.md"; then
    echo "OK  docs have $pat"
  else
    echo "FAIL docs missing $pat"
    fail=$((fail + 1))
  fi
done
if grep -E 'http_port[[:space:]]+3128[[:space:]]*$' "$CHART/SIDECAR.md"; then
  echo "FAIL SIDECAR.md must not show bare http_port 3128"
  fail=$((fail + 1))
else
  echo "OK  SIDECAR.md has no bare http_port 3128"
fi

# Kerberos Argo apps must stay opt-in (not under argocd/apps/).
REPO="$(cd "$CHART/../.." && pwd)"
if [[ -f "$REPO/argocd/apps/kerberos-lab.yaml" ]] || [[ -f "$REPO/argocd/apps/developer-hub-kerberos.yaml" ]]; then
  echo "FAIL kerberos Argo apps must not live under argocd/apps/ (default app-of-apps)"
  fail=$((fail + 1))
else
  echo "OK  kerberos apps not in default argocd/apps/"
fi
if [[ -f "$REPO/argocd/apps-lab/kerberos-lab.yaml" ]] && [[ -f "$REPO/argocd/apps-lab/developer-hub-kerberos.yaml" ]]; then
  echo "OK  kerberos apps under argocd/apps-lab/"
else
  echo "FAIL missing argocd/apps-lab kerberos Applications"
  fail=$((fail + 1))
fi

# Dedicated Hub overlay: sidecar + localhost proxy wiring + Negotiate probes.
HUB_CHART="$(cd "$CHART/../developer-hub" && pwd)"
HUB_OUT="$(mktemp)"
trap 'rm -f "$OUT" "$HUB_OUT" "$DEPLOY_OUT" "$BRIDGE_OUT"' EXIT
helm template developer-hub-kerberos "$HUB_CHART" \
  -f "$HUB_CHART/values.yaml" \
  -f "$HUB_CHART/values-kerberos-lab.yaml" \
  --namespace rhdh-kerberos >"$HUB_OUT"

for pat in \
  "namespace: rhdh-kerberos" \
  "name: developer-hub-kerberos" \
  "rhdh-kerberos-secrets" \
  "use-env-proxy" \
  "enableLocalDb: true" \
  "guest" \
  "name: kerberos-bridge" \
  "name: backstage-backend" \
  "kerberos-bridge-keytab" \
  "kerberos-lab-bridge-ubi" \
  "/healthcheck.sh"
do
  if grep -F -q "$pat" "$HUB_OUT"; then
    echo "OK  hub $pat"
  else
    echo "FAIL hub missing $pat"
    fail=$((fail + 1))
  fi
done

# Sidecar-only must still emit backstage-backend.
SIDECAR_ONLY="$(mktemp)"
helm template t "$HUB_CHART" -f "$HUB_CHART/values.yaml" \
  --set kerberosBridgeSidecar.enabled=true \
  --set catalog.goldenPath.enabled=false \
  --set catalog.demoKitchenSink.enabled=false \
  --set database.external.enabled=false >"$SIDECAR_ONLY"
if grep -q "name: backstage-backend" "$SIDECAR_ONLY" && grep -q "name: kerberos-bridge" "$SIDECAR_ONLY"; then
  echo "OK  sidecar-only patch keeps backstage-backend"
else
  echo "FAIL sidecar-only patch must include backstage-backend + kerberos-bridge"
  fail=$((fail + 1))
fi

EX_SEC="$REPO/examples/rhdh-kerberos-secrets.example.yaml"
if grep -q 'HTTP_PROXY: http://127.0.0.1:3128' "$EX_SEC"; then
  echo "OK  secret example localhost HTTP_PROXY"
else
  echo "FAIL secret example must use http://127.0.0.1:3128"
  fail=$((fail + 1))
fi

if [[ "$fail" -gt 0 ]]; then
  echo "RESULT: $fail failure(s)"
  exit 1
fi
echo "RESULT: OK"
