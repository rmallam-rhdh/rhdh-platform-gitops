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
  need "$f" "https://github.com/rmallam-rhdh/rhdh-platform-gitops"
done
need "$ROOT/argocd/apps/cnpg.yaml" "charts/cnpg"
need "$ROOT/argocd/apps/cnpg-dr.yaml" "charts/cnpg"
need "$ROOT/argocd/apps/cnpg-dr.yaml" "values-dr.yaml"
need "$ROOT/argocd/apps/service-mesh.yaml" "charts/service-mesh"
need "$ROOT/argocd/apps/devspaces.yaml" "charts/devspaces"
need "$ROOT/argocd/apps/developer-hub.yaml" "charts/developer-hub"
need "$ROOT/argocd/apps/squid.yaml" "charts/squid"
if [ -f "$ROOT/argocd/optional/squid.yaml" ]; then
  echo "FAIL squid must live in argocd/apps, not optional"
  fail=1
else
  echo "OK  squid in default app-of-apps"
fi

echo "== unit: helm lint =="
helm lint "$ROOT/charts/cnpg" >/dev/null
helm lint "$ROOT/charts/service-mesh" >/dev/null
helm lint "$ROOT/charts/devspaces" >/dev/null
helm lint "$ROOT/charts/developer-hub" >/dev/null
helm lint "$ROOT/charts/squid" >/dev/null
helm lint "$ROOT/charts/devspaces-user-namespaces" >/dev/null
helm lint "$ROOT/charts/idp-service-chart" >/dev/null
helm lint "$ROOT/charts/gateway-cert-lab" -f "$ROOT/charts/gateway-cert-lab/values-deploy.yaml" >/dev/null

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
need "$DS" "kind: DevWorkspaceOperatorConfig"
need "$DS" "name: devworkspace-operator-config"
need "$DS" "cleanupCronJob:"
need "$HUB" "apps.rosa.rosa-rwx5g.f8y9.p3.openshiftapps.com"
need "$ROOT/golden-path/templates/template-nodejs-golden-path.yaml" "https://devspaces.apps.rosa.rosa-rwx5g.f8y9.p3.openshiftapps.com"
need "$HUB" "kind: Backstage"
need "$HUB" "enableLocalDb: false"
need "$HUB" "name: rhdh-secrets"
forbid "$HUB" "name: rhdh-golden-path"
forbid "$HUB" "/opt/app-root/src/golden-path/"
need "$HUB" "https://github.com/rmallam-rhdh/rhdh-platform-gitops/blob/main/golden-path/templates/template-nodejs-golden-path.yaml"
need "$HUB" "https://github.com/rmallam-rhdh/rhdh-platform-gitops/blob/main/golden-path/templates/template-quarkus-golden-path.yaml"
need "$HUB" "https://github.com/rmallam-rhdh/rhdh-platform-gitops/blob/main/golden-path/templates/template-start-feature-devspaces.yaml"
need "$HUB" "https://github.com/rmallam-rhdh/rhdh-platform-gitops/blob/main/golden-path/templates/template-promote-to-prod.yaml"
need "$ROOT/golden-path/templates/template-promote-to-prod.yaml" "name: promote-service-to-production"
need "$ROOT/golden-path/templates/template-nodejs-golden-path.yaml" "golden-path/skeletons/skeleton-nodejs-golden-path"
need "$ROOT/golden-path/templates/template-quarkus-golden-path.yaml" "golden-path/skeletons/skeleton-quarkus-golden-path"
need "$ROOT/golden-path/templates/template-quarkus-golden-path.yaml" "charts/devspaces-user-namespaces/values.yaml"
need "$ROOT/golden-path/templates/template-nodejs-golden-path.yaml" "charts/devspaces-user-namespaces/values.yaml"
need "$ROOT/argocd/apps/devspaces-user-namespaces.yaml" "charts/devspaces-user-namespaces"
need "$HUB" "name: app-config-command-centre"
need "$HUB" "entity.page.cicd"
need "$HUB" "entity.page.quality-security"
need "$HUB" "entity.page.runtime"
need "$HUB" "entity.page.operations"
need "$HUB" "EntityPagerDutySmallCard"
need "$HUB" "gridColumnEnd:"
need "$HUB" "tabs: mui"
forbid "$HUB" "EntityKialiGraphCard"
forbid "$HUB" "headerColor1:"
need "$HUB" "nonprod-argo"
need "$HUB" "prod-argo"
need "$ROOT/golden-path/skeletons/skeleton-quarkus-golden-path/catalog-info.yaml" "argocd/app-selector"
need "$HUB" "mallamrakeshgmail.onmicrosoft.com"
need "$HUB" "dev374459.service-now.com"
need "$HUB" "kiali-token.istio-system.svc:20001"
need "$HUB" "name: NODE_OPTIONS"
need "$HUB" "--no-node-snapshot --use-env-proxy"
need "$SQUID" "auth_param basic program"
need "$SQUID" "type: ClusterIP"
need "$SQUID" ".service-now.com"
need "$SQUID" ".github.com"
need "$SQUID" "codeload.github.com"

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
forbid "$HUB" "github.com/rmallam/RHDH/tree"
forbid "$HUB" "raw.githubusercontent.com/rmallam/RHDH/"
forbid "$HUB" "demo-ks-plugins"
forbid "$HUB" "kind: ExternalSecret"
forbid "$HUB" "istio.io/dataplane-mode: ambient"
forbid "$HUB" "secretKey: HTTP_PROXY"
forbid "$HUB" "install-dynamic-plugins"
forbid "$SQUID" "kind: ExternalSecret"
forbid "$SQUID" "kind: Route"
forbid "$SQUID" "istio.io/dataplane-mode"
need "$ROOT/examples/rhdh-secrets.example.yaml" ".service-now.com"
need "$ROOT/charts/developer-hub/values.yaml" ".service-now.com"

echo "== system: gateway-cert-lab =="
GWC="$(mktemp)"
helm template gwc "$ROOT/charts/gateway-cert-lab" -f "$ROOT/charts/gateway-cert-lab/values.yaml" -f "$ROOT/charts/gateway-cert-lab/values-deploy.yaml" >"$GWC"
need "$GWC" "kind: Gateway"
need "$GWC" "hostname: orders-gwcert.apps.rosa.rosa-rwx5g.f8y9.p3.openshiftapps.com"
need "$GWC" "termination: passthrough"
forbid "$GWC" "steal-orders"
need "$GWC" "istio-discovery: enabled"
need "$GWC" "kind: ReferenceGrant"
need "$GWC" "namespace: gwcert-payments   # team-owned"
forbid "$GWC" "\\*\\."
forbid "$GWC" "kind: Subscription"
rm -f "$GWC"

echo "== system: venafi-pki-lab & cnpg-tls & developer-hub-cnpg-tls =="
helm lint "$ROOT/charts/venafi-pki-lab" >/dev/null
helm lint "$ROOT/charts/vault-namespace-lab" >/dev/null
VLAB="$(mktemp)"
helm template vlab "$ROOT/charts/vault-namespace-lab" >"$VLAB"
need "$VLAB" "name: vault-enterprise-gw"
need "$VLAB" "name: payments-checkout-service"
need "$VLAB" "name: payments-ledger-service"
need "$VLAB" "name: retail-inventory-service"
forbid "$VLAB" "kind: Subscription"
forbid "$VLAB" "kind: Secret$"
rm -f "$VLAB"
need "$HUB" "internal-plugin-vault-namespace-backend-dynamic-0.1.0.tgz"
need "$HUB" "internal-plugin-vault-namespace-dynamic-0.1.0.tgz"
need "$HUB" "EntityVaultNamespaceCard"
need "$HUB" "includeTransitiveGroupOwnership: true"
need "$HUB" "memberOf=cn=rhdh-users,ou=groups,dc=acme,dc=demo"
need "$HUB" "(!(cn=rhdh-users))"
need "$HUB" "conditionalPoliciesFile: /opt/app-root/src/rbac/rbac-conditional-policies.yaml"
need "$HUB" "name: CHOKIDAR_USEPOLLING"
need "$HUB" "mountPath: /opt/app-root/src/rbac"
need "$HUB" "role:default/team-viewer"
need "$HUB" "role:default/team-editor"
need "$HUB" "g, group:default/team-payments-ro, role:default/team-viewer"
need "$HUB" "g, group:default/team-payments-rw, role:default/team-editor"
need "$HUB" "g, group:default/team-retail-ro, role:default/team-viewer"
need "$HUB" "g, group:default/team-retail-rw, role:default/team-editor"
need "$HUB" "IS_ENTITY_OWNER"
need "$HUB" "payments-checkout-service"
need "$HUB" "retail-inventory-service"
VPKI="$(mktemp)"; CNPG_TLS="$(mktemp)"; HUB_TLS="$(mktemp)"
helm template vpki "$ROOT/charts/venafi-pki-lab" >"$VPKI"
helm template cnpg-tls "$ROOT/charts/cnpg" -f "$ROOT/charts/cnpg/values.yaml" -f "$ROOT/charts/cnpg/values-venafi-tls-lab.yaml" --namespace rhdh-cnpg-tls-test >"$CNPG_TLS"
helm template rhdh-tls "$ROOT/charts/developer-hub" -f "$ROOT/charts/developer-hub/values.yaml" -f "$ROOT/charts/developer-hub/values-cnpg-tls-lab.yaml" --namespace rhdh-cnpg-tls-test >"$HUB_TLS"
need "$VPKI" "kind: ClusterIssuer"
need "$VPKI" "name: simulated-venafi-issuer"
forbid "$VPKI" "kind: Secret$"
need "$CNPG_TLS" "serverTLSSecret: \"cnpg-server-tls\""
need "$CNPG_TLS" "serverCASecret: \"enterprise-ca-chain\""
forbid "$CNPG_TLS" "kind: Secret$"
need "$HUB_TLS" "name: NODE_EXTRA_CA_CERTS"
need "$HUB_TLS" "value: \"/etc/pki/ca-trust/ca.crt\""
need "$HUB_TLS" "rejectUnauthorized: true"
forbid "$HUB_TLS" "NODE_TLS_REJECT_UNAUTHORIZED"
forbid "$HUB_TLS" "kind: Secret$"
rm -f "$VPKI" "$CNPG_TLS" "$HUB_TLS"

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
