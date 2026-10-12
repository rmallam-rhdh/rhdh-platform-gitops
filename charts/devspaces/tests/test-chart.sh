#!/usr/bin/env bash
set -euo pipefail
CHART="$(cd "$(dirname "$0")/.." && pwd)"
helm lint "$CHART"
OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT
helm template ds "$CHART" --namespace openshift-devspaces >"$OUT"
fail=0
for pat in \
  "kind: CheCluster" \
  "ingress.openshift.io/shard: devspaces" \
  "networkPolicy:" \
  "pvcStrategy: \"per-user\"" \
  "disableContainerRunCapabilities: true" \
  "openShiftSecurityContextConstraint: \"container-build\"" \
  "maxNumberOfRunningWorkspacesPerUser: 1"
do
  grep -q "$pat" "$OUT" || { echo "FAIL missing $pat"; fail=1; }
done
if grep -qE "kind: Subscription|kind: OperatorGroup|kind: IngressController" "$OUT"; then
  echo "FAIL operator or ingress shard must not be rendered by the chart"
  fail=1
fi
[ "$fail" -eq 0 ] || exit 1
echo "Dev Spaces chart tests passed"
