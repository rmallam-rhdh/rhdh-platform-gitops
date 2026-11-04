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
  "maxNumberOfRunningWorkspacesPerUser: 1" \
  "kind: DevWorkspaceOperatorConfig" \
  "name: devworkspace-operator-config" \
  "cleanupCronJob:" \
  "enable: true" \
  "dryRun: false" \
  "retainTime: 2592000" \
  'schedule: "0 0 1 * *"'
do
  grep -Fq "$pat" "$OUT" || { echo "FAIL missing $pat"; fail=1; }
done
if grep -Eq 'name: devworkspace-config$' "$OUT"; then
  echo "FAIL cleanup must use global DWOC name, not Che-owned devworkspace-config"
  fail=1
fi
if grep -Fq "ingress.openshift.io/shard" "$OUT"; then
  echo "FAIL CheCluster must not select a Dev Spaces ingress shard on this cluster"
  fail=1
fi
if grep -Fq "sandbox3257" "$OUT"; then
  echo "FAIL CheCluster must not use the sandbox shard domain"
  fail=1
fi
if grep -qE "kind: Subscription|kind: OperatorGroup|kind: IngressController" "$OUT"; then
  echo "FAIL operator or IngressController must not be rendered by the chart"
  fail=1
fi
# Disabled cleanup must omit the global DWOC
OFF="$(mktemp)"
helm template ds "$CHART" \
  -f "$CHART/values.yaml" \
  -f "$CHART/values-deploy.yaml" \
  --set cleanupCronJob.enable=false \
  --namespace openshift-devspaces >"$OFF"
if grep -Fq "kind: DevWorkspaceOperatorConfig" "$OFF"; then
  echo "FAIL DWOC must not render when cleanupCronJob.enable=false"
  fail=1
fi
rm -f "$OFF"
[ "$fail" -eq 0 ] || exit 1
echo "Dev Spaces chart tests passed"
