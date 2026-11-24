#!/usr/bin/env bash
# ==============================================================================
# Post-Install Cluster Bootstrap & Seeding Script (ROSA / OpenShift)
#
# Recreates the complete Day-1 + Day-2 + Lab state from scratch on a fresh OpenShift
# cluster, including:
#   1. Enabling OpenShift User Workload Monitoring (required for Ambient Mesh Kiali metrics)
#   2. Day-1 Operators & Tools (`rmallam-rhdh/RHDH-SM-DevSpaces` -> `bootstrap/root-app.yaml`)
#   3. Pre-requisite Secrets (`squid-htpasswd`, `rhdh-secrets` + auto-populated `KUBE_SA_TOKEN`,
#      `KUBE_CA_DATA`, `ARGOCD_ADMIN_PASSWORD`, and `jenkins/sonarqube-token`)
#   4. Day-2 Platform Applications (`argocd/app-of-apps.yaml` -> `idp-platform`)
#   5. Lab & Command Centre Applications (`argocd/apps-lab/*.yaml` + `orders-api`)
#   6. Jenkins GitHub Organization Folder (`demo`) for Golden Path webhook builds
#
# Usage:
#   export CLUSTER_BASE_DOMAIN="apps.rosa.<cluster>.<domain>.p3.openshiftapps.com"
#   export RHDH_SECRETS_FILE="/path/to/filled-rhdh-secrets.yaml"   # optional if already applied
#   ./scripts/bootstrap-cluster.sh
# ==============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> [1/6] Checking OpenShift login and cluster base domain..."
oc whoami >/dev/null
if [ -z "${CLUSTER_BASE_DOMAIN:-}" ]; then
  INGRESS_DOMAIN="$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')"
  export CLUSTER_BASE_DOMAIN="$INGRESS_DOMAIN"
fi
echo "    Cluster Base Domain: ${CLUSTER_BASE_DOMAIN}"

echo "==> [2/6] Enabling OpenShift User Workload Monitoring (for Istio Ambient & Kiali PodMonitors)..."
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
EOF

echo "==> [3/6] Ensuring namespaces and pre-requisite Secrets exist..."
for ns in rhdh squid jenkins sonarqube demo-dev demo-prod; do
  oc get ns "$ns" >/dev/null 2>&1 || oc create ns "$ns"
done
oc label ns demo-dev istio.io/dataplane-mode=ambient istio-discovery=enabled acme.io/mesh-enroll=true app.kubernetes.io/part-of=acme-platform --overwrite

if ! oc get secret squid-htpasswd -n squid >/dev/null 2>&1; then
  echo "    Applying default squid-htpasswd Secret from examples/squid-htpasswd.example.yaml..."
  oc apply -n squid -f "$ROOT/examples/squid-htpasswd.example.yaml"
fi

if [ -n "${RHDH_SECRETS_FILE:-}" ] && [ -f "${RHDH_SECRETS_FILE}" ]; then
  echo "    Applying RHDH_SECRETS_FILE (${RHDH_SECRETS_FILE})..."
  oc apply -n rhdh -f "${RHDH_SECRETS_FILE}"
elif ! oc get secret rhdh-secrets -n rhdh >/dev/null 2>&1; then
  echo "    WARNING: Secret rhdh/rhdh-secrets not found! Applying examples/rhdh-secrets.example.yaml as placeholder..."
  oc apply -n rhdh -f "$ROOT/examples/rhdh-secrets.example.yaml"
fi

echo "==> [4/6] Creating permanent ServiceAccount token Secret (rhdh/rhdh-k8s-sa-token) & wiring dynamic cluster credentials..."
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: rhdh-k8s-sa-token
  namespace: rhdh
  annotations:
    kubernetes.io/service-account.name: default
type: kubernetes.io/service-account-token
EOF

# Wait for token controller to populate rhdh-k8s-sa-token
for _ in $(seq 1 15); do
  SA_TOKEN_B64="$(oc get secret rhdh-k8s-sa-token -n rhdh -o jsonpath='{.data.token}' 2>/dev/null || true)"
  if [ -n "$SA_TOKEN_B64" ]; then
    break
  fi
  sleep 1
done

SA_CA_B64="$(oc get secret rhdh-k8s-sa-token -n rhdh -o jsonpath='{.data.ca\.crt}' 2>/dev/null || true)"
if [ -n "$SA_TOKEN_B64" ]; then
  oc patch secret rhdh-secrets -n rhdh --type merge -p "{\"data\":{\"KUBE_SA_TOKEN\":\"${SA_TOKEN_B64}\",\"KUBE_CA_DATA\":\"${SA_CA_B64}\"}}"
  echo "    Updated KUBE_SA_TOKEN and KUBE_CA_DATA in Secret rhdh/rhdh-secrets."
fi

if oc get secret openshift-gitops-cluster -n openshift-gitops >/dev/null 2>&1; then
  ARGO_PASS_B64="$(oc get secret openshift-gitops-cluster -n openshift-gitops -o jsonpath='{.data.admin\.password}')"
  if [ -n "$ARGO_PASS_B64" ]; then
    oc patch secret rhdh-secrets -n rhdh --type merge -p "{\"data\":{\"ARGOCD_ADMIN_PASSWORD\":\"${ARGO_PASS_B64}\"}}"
    echo "    Updated ARGOCD_ADMIN_PASSWORD in Secret rhdh/rhdh-secrets from openshift-gitops-cluster."
  fi
fi

# Propagate SONARQUBE_API_KEY from rhdh/rhdh-secrets to jenkins/sonarqube-token so Jenkins pipelines can scan
SONAR_KEY_B64="$(oc get secret rhdh-secrets -n rhdh -o jsonpath='{.data.SONARQUBE_API_KEY}' 2>/dev/null || true)"
if [ -n "$SONAR_KEY_B64" ]; then
  cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: sonarqube-token
  namespace: jenkins
type: Opaque
data:
  SONAR_TOKEN: ${SONAR_KEY_B64}
EOF
  echo "    Synced Secret jenkins/sonarqube-token from rhdh/rhdh-secrets (SONARQUBE_API_KEY)."
fi

echo "==> [5/6] Applying Multicluster Redirector RBAC and Day-2 Platform App-of-Apps (argocd/app-of-apps.yaml)..."
oc apply -f "$ROOT/manifests/devspaces-multicluster-redirector/rbac.yaml"
oc apply -f "$ROOT/argocd/app-of-apps.yaml"

echo "==> [6/6] Applying Lab & Command Centre Demo Applications (argocd/apps-lab/)..."
oc apply -f "$ROOT/argocd/apps-lab/cert-manager-operator.yaml"
oc apply -f "$ROOT/argocd/apps-lab/venafi-pki-lab.yaml"
oc apply -f "$ROOT/argocd/apps-lab/cnpg-venafi-tls.yaml"
oc apply -f "$ROOT/argocd/apps-lab/developer-hub-cnpg-tls.yaml"
oc apply -f "$ROOT/argocd/apps-lab/vault-namespace-lab.yaml"
oc apply -f "$ROOT/argocd/apps-lab/gateway-cert-lab.yaml"
oc apply -f "$ROOT/argocd/apps-lab/command-centre-demo-apps.yaml"

if [ "${ENABLE_KERBEROS_LAB:-false}" = "true" ]; then
  oc apply -f "$ROOT/argocd/apps-lab/kerberos-lab.yaml"
  oc apply -f "$ROOT/argocd/apps-lab/developer-hub-kerberos.yaml"
fi

echo "Bootstrap manifests applied. Monitor sync status with:"
echo "  oc get applications.argoproj.io -n openshift-gitops"
