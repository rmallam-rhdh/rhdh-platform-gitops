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
  "name: bridge" \
  "app.kubernetes.io/component: kdc" \
  "app.kubernetes.io/component: corporate-proxy" \
  "app.kubernetes.io/component: bridge" \
  "kind: NetworkPolicy" \
  "rhdh-kerberos" \
  "REALM" \
  "LAB.LOCAL" \
  "system:openshift:scc:anyuid" \
  "serviceAccountName: kerberos-lab"
do
  if grep -q "$pat" "$OUT"; then
    echo "OK  $pat"
  else
    echo "FAIL missing $pat"
    fail=$((fail + 1))
  fi
done

# Cluster overlay: standalone bridge off; corporate NP still allows Hub ns.
DEPLOY_OUT="$(mktemp)"
helm template kerberos-lab "$CHART" \
  -f "$CHART/values.yaml" \
  -f "$CHART/values-deploy.yaml" >"$DEPLOY_OUT"
if awk '/^kind: Deployment$/{d=1} d&&/^---$/{d=0} d&&/name: bridge/{found=1} END{exit !found}' "$DEPLOY_OUT"; then
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
  "$CHART/scripts/build-images.sh" \
  "$CHART/scripts/sync-bridge-keytab-secret.sh" \
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
for pat in \
  "login=NEGOTIATE" \
  "127.0.0.1:3128" \
  "bridge-client.keytab" \
  "HTTP/" \
  "kerberos-bridge" \
  "CORPORATE_PROXY_HOSTNAME"
do
  if grep -q "$pat" "$CHART/SIDECAR.md"; then
    echo "OK  SIDECAR.md has $pat"
  else
    echo "FAIL SIDECAR.md missing $pat"
    fail=$((fail + 1))
  fi
done

# Dedicated Hub overlay: sidecar + localhost proxy wiring.
HUB_CHART="$(cd "$CHART/../developer-hub" && pwd)"
HUB_OUT="$(mktemp)"
trap 'rm -f "$OUT" "$HUB_OUT" "$DEPLOY_OUT"' EXIT
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
  "kerberos-bridge-keytab" \
  "kerberos-lab-bridge-ubi"
do
  if grep -F -q "$pat" "$HUB_OUT"; then
    echo "OK  hub $pat"
  else
    echo "FAIL hub missing $pat"
    fail=$((fail + 1))
  fi
done
EX_SEC="$(cd "$HUB_CHART/../.." && pwd)/examples/rhdh-kerberos-secrets.example.yaml"
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
