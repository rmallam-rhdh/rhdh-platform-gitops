#!/usr/bin/env bash
# Unit: helm lint the four CR charts; Argo apps point at charts/.
# System: rendered YAML is CRs only — no Subscription or OperatorGroup.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
command -v helm >/dev/null || { echo "missing helm" >&2; exit 1; }

need() {
  local file="$1" pat="$2"
  if grep -q -e "$pat" "$file"; then
    echo "OK  $pat"
  else
    echo "FAIL missing $pat"
    fail=1
  fi
}

forbid() {
  local file="$1" pat="$2"
  if grep -q -e "$pat" "$file"; then
    echo "FAIL must not contain $pat"
    fail=1
  else
    echo "OK  no $pat"
  fi
}

echo "== unit: Argo paths =="
for f in "$ROOT"/argocd/app-of-apps.yaml "$ROOT"/argocd/apps/*.yaml; do
  need "$f" "https://github.com/rmallam/rhdh-platform-gitops"
done
need "$ROOT/argocd/apps/cnpg.yaml" "charts/cnpg"
need "$ROOT/argocd/apps/cnpg-dr.yaml" "charts/cnpg"
need "$ROOT/argocd/apps/cnpg-dr.yaml" "values-dr.yaml"
need "$ROOT/argocd/apps/service-mesh.yaml" "charts/service-mesh"
need "$ROOT/argocd/apps/devspaces.yaml" "charts/devspaces"
need "$ROOT/argocd/apps/developer-hub.yaml" "charts/developer-hub"
need "$ROOT/argocd/apps/squid.yaml" "charts/squid"

echo "== unit: helm lint =="
helm lint "$ROOT/charts/cnpg" >/dev/null
helm lint "$ROOT/charts/service-mesh" >/dev/null
helm lint "$ROOT/charts/devspaces" >/dev/null
helm lint "$ROOT/charts/developer-hub" >/dev/null
helm lint "$ROOT/charts/squid" >/dev/null

CNPG="$(mktemp)"; DR="$(mktemp)"; SM="$(mktemp)"; DS="$(mktemp)"; HUB="$(mktemp)"; SQUID="$(mktemp)"
trap 'rm -f "$CNPG" "$DR" "$SM" "$DS" "$HUB" "$SQUID"' EXIT

helm template cnpg "$ROOT/charts/cnpg" --namespace rhdh >"$CNPG"
helm template cnpg-dr "$ROOT/charts/cnpg" -f "$ROOT/charts/cnpg/values-dr.yaml" --namespace rhdh-dr >"$DR"
helm template mesh "$ROOT/charts/service-mesh" >"$SM"
helm template ds "$ROOT/charts/devspaces" \
  -f "$ROOT/charts/devspaces/values.yaml" \
  -f "$ROOT/charts/devspaces/values-deploy.yaml" \
  --namespace openshift-devspaces >"$DS"
helm template rhdh "$ROOT/charts/developer-hub" \
  -f "$ROOT/charts/developer-hub/values.yaml" \
  -f "$ROOT/charts/developer-hub/values-demo.yaml" \
  -f "$ROOT/charts/developer-hub/values-deploy.yaml" \
  --namespace rhdh >"$HUB"
helm template squid "$ROOT/charts/squid" --namespace squid >"$SQUID"

echo "== system: CR kinds =="
need "$CNPG" "kind: Cluster$"
need "$CNPG" "name: rhdh-pg"
need "$CNPG" "instances: 3"
need "$DR" "name: rhdh-dr"
need "$DR" "name: rhdh-pg-dr"
need "$DR" "instances: 3"
need "$SM" "kind: Istio"
need "$SM" "profile: ambient"
need "$SM" "kind: IstioCNI"
need "$SM" "kind: ZTunnel"
need "$SM" "kind: Kiali"
need "$DS" "kind: CheCluster"
need "$HUB" "apps.rosa.rosa-rwx5g.f8y9.p3.openshiftapps.com"
need "$HUB" "https://devspaces.apps.rosa.rosa-rwx5g.f8y9.p3.openshiftapps.com"
need "$HUB" "kind: Backstage"
need "$HUB" "enableLocalDb: false"
need "$HUB" "name: rhdh-secrets"
need "$HUB" "name: rhdh-golden-path"
need "$HUB" "acme-nodejs-golden-path"
need "$HUB" "acme-quarkus-golden-path"
need "$HUB" "/opt/app-root/src/golden-path/template-nodejs-golden-path.yaml"
need "$HUB" "/opt/app-root/src/golden-path/template-quarkus-golden-path.yaml"
need "$HUB" "mallamrakeshgmail.onmicrosoft.com"
need "$SQUID" "auth_param basic program"
need "$SQUID" "type: ClusterIP"
need "$SQUID" ".service-now.com"

echo "== system: no operator installs =="
for out in "$CNPG" "$DR" "$SM" "$DS" "$HUB" "$SQUID"; do
  forbid "$out" "kind: Subscription"
  forbid "$out" "kind: OperatorGroup"
  forbid "$out" "kind: CatalogSource"
done
# Hub chart must not also emit the Postgres Cluster (charts/cnpg owns it).
forbid "$HUB" "kind: Cluster$"
forbid "$DS" "kind: IngressController"
forbid "$DS" "ingress.openshift.io/shard"
forbid "$HUB" "apps.rosa.rosa-89s85"
forbid "$HUB" "sandbox3257"
forbid "$HUB" "kind: ExternalSecret"
forbid "$HUB" "istio.io/dataplane-mode: ambient"
forbid "$HUB" "secretKey: HTTP_PROXY"
forbid "$HUB" "install-dynamic-plugins"
forbid "$SQUID" "kind: Route"
forbid "$SQUID" "istio.io/dataplane-mode"

if [ ! -d "$ROOT/components" ]; then
  echo "OK  components/ removed"
else
  echo "FAIL components/ still present"
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "Platform GitOps tests failed"
  exit 1
fi
echo "Platform GitOps tests passed"
