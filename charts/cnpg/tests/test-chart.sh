#!/usr/bin/env bash
set -euo pipefail
CHART="$(cd "$(dirname "$0")/.." && pwd)"
helm lint "$CHART"
OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT
helm template cnpg "$CHART" --namespace rhdh >"$OUT"
fail=0
for pat in "kind: Cluster" "name: rhdh-pg" "kind: Namespace"; do
  grep -q "$pat" "$OUT" || { echo "FAIL $pat"; fail=1; }
done
if grep -qE "kind: Subscription|kind: OperatorGroup" "$OUT"; then
  echo "FAIL operator install must not be rendered"
  fail=1
fi
[ "$fail" -eq 0 ] || exit 1
echo "CNPG chart tests passed"
