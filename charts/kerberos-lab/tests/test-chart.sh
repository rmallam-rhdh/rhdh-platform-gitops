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

# Images and scripts exist
for f in \
  "$CHART/images/kdc/Containerfile" \
  "$CHART/images/corporate-proxy/Containerfile" \
  "$CHART/images/bridge/Containerfile" \
  "$CHART/scripts/build-images.sh"
do
  if [[ -f "$f" ]]; then
    echo "OK  file $f"
  else
    echo "FAIL missing $f"
    fail=$((fail + 1))
  fi
done

# Dedicated Hub overlay (sibling chart) must wire proxy + guest + separate ns.
HUB_CHART="$(cd "$CHART/../developer-hub" && pwd)"
HUB_OUT="$(mktemp)"
trap 'rm -f "$OUT" "$HUB_OUT"' EXIT
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
  "guest"
do
  if grep -F -q "$pat" "$HUB_OUT"; then
    echo "OK  hub $pat"
  else
    echo "FAIL hub missing $pat"
    fail=$((fail + 1))
  fi
done

if [[ "$fail" -gt 0 ]]; then
  echo "RESULT: $fail failure(s)"
  exit 1
fi
echo "RESULT: OK"
