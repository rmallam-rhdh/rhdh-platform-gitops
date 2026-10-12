#!/usr/bin/env bash
set -euo pipefail
CHART="$(cd "$(dirname "$0")/.." && pwd)"
helm lint "$CHART"
OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT
helm template ds "$CHART" --namespace openshift-devspaces >"$OUT"
fail=0
grep -q "kind: CheCluster" "$OUT" || { echo "FAIL CheCluster"; fail=1; }
if grep -qE "kind: Subscription|kind: OperatorGroup" "$OUT"; then
  echo "FAIL operator install must not be rendered"
  fail=1
fi
[ "$fail" -eq 0 ] || exit 1
echo "Dev Spaces chart tests passed"
