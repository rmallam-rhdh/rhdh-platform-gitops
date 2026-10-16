#!/usr/bin/env bash
set -euo pipefail
CHART="$(cd "$(dirname "$0")/.." && pwd)"
helm lint "$CHART"
OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT
helm template ds "$CHART" \
  -f "$CHART/values.yaml" \
  -f "$CHART/values-deploy.yaml" \
  --namespace openshift-devspaces >"$OUT"
fail=0
for pat in \
  "kind: CheCluster" \
  "networkPolicy:" \
  "pvcStrategy: \"per-user\"" \
  "disableContainerRunCapabilities: true" \
  "openShiftSecurityContextConstraint: \"container-build\"" \
  "maxNumberOfRunningWorkspacesPerUser: 1"
do
  grep -q "$pat" "$OUT" || { echo "FAIL missing $pat"; fail=1; }
done
if grep -q "ingress.openshift.io/shard" "$OUT"; then
  echo "FAIL CheCluster must not select a Dev Spaces ingress shard on this cluster"
  fail=1
fi
if grep -q "sandbox3257" "$OUT"; then
  echo "FAIL CheCluster must not use the sandbox shard domain"
  fail=1
fi
if grep -qE "kind: Subscription|kind: OperatorGroup|kind: IngressController" "$OUT"; then
  echo "FAIL operator or IngressController must not be rendered by the chart"
  fail=1
fi
[ "$fail" -eq 0 ] || exit 1
echo "Dev Spaces chart tests passed"
