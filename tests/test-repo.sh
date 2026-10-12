#!/usr/bin/env bash
# Unit: kustomize/helm render the four stacks; Argo apps point at this repo.
# System: rendered YAML contains the operator CRs and Hub CNPG cluster.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
need_bin() { command -v "$1" >/dev/null || { echo "missing $1" >&2; exit 1; }; }

kustomize_build() {
  local path="$1"
  # Lab/production overlays include ../../base — disable the load restrictor.
  if command -v kustomize >/dev/null; then
    kustomize build "$path"
  elif command -v oc >/dev/null; then
    oc kustomize "$path"
  else
    kubectl kustomize "$path"
  fi
}

need() {
  local file="$1" pat="$2"
  if grep -q "$pat" "$file"; then
    echo "OK  $pat"
  else
    echo "FAIL missing $pat"
    fail=1
  fi
}

need_bin helm
command -v kustomize >/dev/null || command -v oc >/dev/null || command -v kubectl >/dev/null \
  || { echo "need kustomize, oc, or kubectl" >&2; exit 1; }

CNPG="$(mktemp)"
SM="$(mktemp)"
DS="$(mktemp)"
HUB="$(mktemp)"
trap 'rm -f "$CNPG" "$SM" "$DS" "$HUB"' EXIT

echo "== unit: Argo repo URL =="
for f in "$ROOT"/argocd/app-of-apps.yaml "$ROOT"/argocd/apps/*.yaml; do
  need "$f" "https://github.com/rmallam/rhdh-platform-gitops"
done
need "$ROOT/argocd/apps/cnpg.yaml" "components/cnpg/base"
need "$ROOT/argocd/apps/service-mesh.yaml" "components/service-mesh/overlays/lab"
need "$ROOT/argocd/apps/devspaces.yaml" "components/devspaces/overlays/production"
need "$ROOT/argocd/apps/developer-hub.yaml" "values-deploy.yaml"

echo "== unit: kustomize / helm lint =="
kustomize_build "$ROOT/components/cnpg/base" >"$CNPG"
kustomize_build "$ROOT/components/service-mesh/overlays/lab" >"$SM"
kustomize_build "$ROOT/components/devspaces/overlays/production" >"$DS"
helm lint "$ROOT/charts/developer-hub" >/dev/null
helm template rhdh "$ROOT/charts/developer-hub" \
  -f "$ROOT/charts/developer-hub/values.yaml" \
  -f "$ROOT/charts/developer-hub/values-deploy.yaml" \
  --namespace rhdh >"$HUB"

echo "== system: rendered kinds =="
need "$CNPG" "kind: Subscription"
need "$CNPG" "name: cloudnative-pg"
need "$CNPG" "channel: stable-v1"
need "$SM" "kind: Istio"
need "$SM" "kind: IstioCNI"
need "$SM" "kind: ZTunnel"
need "$SM" "kind: Kiali"
need "$SM" "source: redhat-operators"
need "$DS" "kind: CheCluster"
need "$DS" "name: devspaces"
need "$HUB" "kind: Backstage"
need "$HUB" "kind: Cluster"
need "$HUB" "name: rhdh-pg"
need "$HUB" "enableLocalDb: false"
need "$HUB" "name: rhdh-secrets"

if [ "$fail" -ne 0 ]; then
  echo "Platform GitOps tests failed"
  exit 1
fi
echo "Platform GitOps tests passed"
