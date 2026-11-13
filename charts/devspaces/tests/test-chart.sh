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
  "disableContainerBuildCapabilities: true" \
  "disableContainerRunCapabilities: true" \
  "disableWorkspaceCaBundleMount: true" \
  "allowPrivilegeEscalation: false" \
  "maxNumberOfRunningWorkspacesPerUser: 1" \
  "maxNumberOfRunningWorkspacesPerCluster: 10" \
  "imagePullPolicy: \"IfNotPresent\"" \
  "openVSXURL: \"\"" \
  "containerResourceCaps:" \
  "memory: 8Gi" \
  "defaultContainerResources:" \
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

# Builds off → no container-build SCC stanza
if grep -Fq "openShiftSecurityContextConstraint" "$OUT"; then
  echo "FAIL containerBuildConfiguration must not render when builds are disabled"
  fail=1
fi
if grep -Fq "imagePuller:" "$OUT" && grep -Fq "enable: true" "$OUT"; then
  # only fail if imagePuller.enable true specifically
  if awk '/imagePuller:/{p=1} p&&/enable: true/{found=1} p&&/^[^ ]/{p=0} END{exit !found}' "$OUT"; then
    echo "FAIL imagePuller must stay disabled"
    fail=1
  fi
fi

# Caps must appear on the global DWOC (enforcement path), not only CheCluster.
if ! awk '/kind: DevWorkspaceOperatorConfig/{in_dwoc=1} in_dwoc && /containerResourceCaps:/{found=1} END{exit !found}' "$OUT"; then
  echo "FAIL containerResourceCaps must be rendered on global DevWorkspaceOperatorConfig"
  fail=1
fi
if grep -Eq 'name: devworkspace-config$' "$OUT"; then
  echo "FAIL cleanup must use global DWOC name, not Che-owned devworkspace-config"
  fail=1
fi

# With caps configured, DWOC still renders when cleanup is disabled
OFF_CAPS="$(mktemp)"
helm template ds "$CHART" \
  -f "$CHART/values.yaml" \
  -f "$CHART/values-deploy.yaml" \
  --set cleanupCronJob.enable=false \
  --namespace openshift-devspaces >"$OFF_CAPS"
if ! grep -Fq "kind: DevWorkspaceOperatorConfig" "$OFF_CAPS"; then
  echo "FAIL DWOC must still render resource caps when cleanupCronJob.enable=false"
  fail=1
fi
if ! grep -Fq "containerResourceCaps:" "$OFF_CAPS"; then
  echo "FAIL caps missing from DWOC when cleanup disabled"
  fail=1
fi
rm -f "$OFF_CAPS"

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

# Deny-list without embedding banned tokens
deny_pat="$(printf '%spac|%sl' 'west' 'wnz')"
if grep -qiE "${deny_pat}" "$OUT" "$CHART/values.yaml" "$CHART/HARDENING.md" "$CHART/examples/che-git-custom-cert.yaml" 2>/dev/null; then
  echo "FAIL denied customer string in chart outputs"
  fail=1
fi

# Example cert ConfigMap contract
grep -Fq 'app.kubernetes.io/part-of: che.eclipse.org' "$CHART/examples/che-git-custom-cert.yaml" \
  || { echo "FAIL cert example missing Che label"; fail=1; }
grep -Fq 'disableWorkspaceCaBundleMount' "$CHART/HARDENING.md" \
  || { echo "FAIL HARDENING.md must document CA mount"; fail=1; }

# With no cleanup and no resource settings, DWOC should not render
EMPTY="$(mktemp)"
helm template ds "$CHART" \
  -f "$CHART/values.yaml" \
  -f "$CHART/values-deploy.yaml" \
  --set cleanupCronJob.enable=false \
  --set cheCluster.containerResourceCaps=null \
  --set cheCluster.defaultContainerResources=null \
  --namespace openshift-devspaces >"$EMPTY"
if grep -Fq "kind: DevWorkspaceOperatorConfig" "$EMPTY"; then
  echo "FAIL DWOC must not render when cleanup and resource settings are disabled"
  fail=1
fi
rm -f "$EMPTY"

[ "$fail" -eq 0 ] || exit 1
echo "Dev Spaces chart tests passed"
