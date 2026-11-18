#!/usr/bin/env bash
set -euo pipefail
CHART="$(cd "$(dirname "$0")/.." && pwd)"
helm lint "$CHART"
OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT
helm template mesh "$CHART" >"$OUT"
fail=0
for pat in "kind: Istio" "kind: IstioCNI" "kind: ZTunnel" "kind: Kiali"; do
  grep -q "$pat" "$OUT" || { echo "FAIL $pat"; fail=1; }
done
if grep -qE "kind: Subscription|kind: CatalogSource|kind: OperatorGroup" "$OUT"; then
  echo "FAIL operator install must not be rendered"
  fail=1
fi
# Mesh-level PeerAuthentication must be off by default until mtls.enabled=true.
if grep -q "kind: PeerAuthentication" "$OUT"; then
  echo "FAIL PeerAuthentication must not render when mtls.enabled=false"
  fail=1
fi

# Mesh-level STRICT mTLS enabled.
MTLS_STRICT="$(mktemp)"
helm template mesh "$CHART" --set mtls.enabled=true -s templates/peerauthentication.yaml >"$MTLS_STRICT"
for pat in \
  "apiVersion: security.istio.io/v1" \
  "kind: PeerAuthentication" \
  "name: default" \
  "namespace: istio-system" \
  'argocd.argoproj.io/sync-wave: "4"' \
  "SkipDryRunOnMissingResource=true" \
  "mode: STRICT"
do
  grep -Fq -- "$pat" "$MTLS_STRICT" || { echo "FAIL mtls STRICT missing: $pat"; fail=1; }
done
# Root mesh-wide PeerAuthentication must not carry a workload selector.
if grep -Fq "selector:" "$MTLS_STRICT"; then
  echo "FAIL mesh-wide PeerAuthentication must not include selector"
  fail=1
fi
rm -f "$MTLS_STRICT"

# Mesh-level PERMISSIVE mode (case-insensitive normalization).
MTLS_PERM="$(mktemp)"
helm template mesh "$CHART" --set mtls.enabled=true --set mtls.mode=permissive >"$MTLS_PERM"
grep -Fq "mode: PERMISSIVE" "$MTLS_PERM" || { echo "FAIL expected mode: PERMISSIVE"; fail=1; }
rm -f "$MTLS_PERM"

# Invalid mtls.mode must fail at template time.
if helm template mesh "$CHART" --set mtls.enabled=true --set mtls.mode=INVALID >/dev/null 2>&1; then
  echo "FAIL expected template error for invalid mtls.mode"
  fail=1
fi

[ "$fail" -eq 0 ] || exit 1
echo "Service Mesh chart tests passed"
