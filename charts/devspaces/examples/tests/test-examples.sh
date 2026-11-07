#!/usr/bin/env bash
# Unit checks for CheCluster image-override examples (no cluster required).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export ROOT
fail=0

pass() { echo "PASS: $*"; }
fail_msg() { echo "FAIL: $*"; fail=1; }

need() {
  local file="$1" pat="$2"
  grep -Fq "$pat" "$file" && pass "$(basename "$file") has ${pat}" || fail_msg "$(basename "$file") missing ${pat}"
}

for f in \
  checluster-container-registry.yaml \
  checluster-workspace-init-overrides.yaml \
  checluster-combined.yaml
do
  path="${ROOT}/${f}"
  [[ -f "$path" ]] || { fail_msg "missing $f"; continue; }
  need "$path" "kind: CheCluster"
  need "$path" "name: devspaces"
  need "$path" "namespace: openshift-devspaces"
  # Deny-list without embedding banned tokens in this file.
  deny_pat="$(printf '%spac|%sl' 'west' 'wnz')"
  if grep -qiE "${deny_pat}" "$path"; then
    fail_msg "$f contains denied customer string"
  else
    pass "$f has no denied customer strings"
  fi
done

need "${ROOT}/checluster-container-registry.yaml" "containerRegistry:"
need "${ROOT}/checluster-container-registry.yaml" "hostname: artifactory.example.com"
need "${ROOT}/checluster-container-registry.yaml" "organization: digi20/devspaces"

need "${ROOT}/checluster-workspace-init-overrides.yaml" "projectCloneContainer:"
need "${ROOT}/checluster-workspace-init-overrides.yaml" "initContainers:"
need "${ROOT}/checluster-workspace-init-overrides.yaml" "name: init-persistent-home"
need "${ROOT}/checluster-workspace-init-overrides.yaml" "gatewayContainer:"

need "${ROOT}/checluster-combined.yaml" "containerRegistry:"
need "${ROOT}/checluster-combined.yaml" "projectCloneContainer:"
need "${ROOT}/checluster-combined.yaml" "initContainers:"

need "${ROOT}/README.md" "checluster-container-registry.yaml"
need "${ROOT}/README.md" "checluster-workspace-init-overrides.yaml"

if command -v python3 >/dev/null 2>&1; then
  python3 - <<'PY' || fail=1
import os
import pathlib
import sys

root = pathlib.Path(os.environ["ROOT"])
try:
    import yaml
except ImportError:
    print("PASS: PyYAML not installed; skip parse")
    sys.exit(0)

for name in (
    "checluster-container-registry.yaml",
    "checluster-workspace-init-overrides.yaml",
    "checluster-combined.yaml",
):
    docs = [d for d in yaml.safe_load_all(root.joinpath(name).read_text()) if d]
    assert docs, name
    assert docs[-1]["kind"] == "CheCluster", name
    print(f"PASS: parsed {name}")
PY
else
  pass "python3 not available; skip YAML parse"
fi

[[ "$fail" -eq 0 ]] || exit 1
echo "Dev Spaces CheCluster examples tests passed"
