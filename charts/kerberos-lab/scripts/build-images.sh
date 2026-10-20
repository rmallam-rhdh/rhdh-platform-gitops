#!/usr/bin/env bash
# Build lab images with podman. Optionally push to a registry.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="${TAG:-0.1.0}"
REGISTRY="${REGISTRY:-}" # e.g. image-registry.openshift-image-registry.svc:5000/kerberos-lab

need() { command -v "$1" >/dev/null || { echo "missing $1" >&2; exit 1; }; }
need podman

build_one() {
  local name="$1" dir="$2"
  local local_tag="kerberos-lab-${name}:${TAG}"
  echo "==> building ${local_tag}"
  podman build -t "$local_tag" -f "${dir}/Containerfile" "$dir"
  if [[ -n "$REGISTRY" ]]; then
    local remote="${REGISTRY}/kerberos-lab-${name}:${TAG}"
    podman tag "$local_tag" "$remote"
    podman push "$remote"
    echo "pushed ${remote}"
  fi
}

build_one kdc "${ROOT}/images/kdc"
build_one corporate-proxy "${ROOT}/images/corporate-proxy"
build_one bridge "${ROOT}/images/bridge"

echo "Done. Set charts/kerberos-lab/values-deploy.yaml images.* to your registry tags."
