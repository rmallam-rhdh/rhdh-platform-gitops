#!/usr/bin/env bash
# Unit + render checks for the multicluster redirector chart.
set -euo pipefail
CHART="$(cd "$(dirname "$0")/.." && pwd)"
helm lint "$CHART"
helm lint "$CHART" -f "$CHART/values.yaml" -f "$CHART/values-deploy.yaml"

OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT

# Default customer render (values.yaml + values-deploy.yaml) auto-generates random
# <release>-session-secret (zero Vault/ESO sessionSecret config) and names all resources after .Release.Name.
helm template devspaces-multicluster-redirector "$CHART" \
  -f "$CHART/values.yaml" \
  -f "$CHART/values-deploy.yaml" \
  --namespace devspaces-redirector >"$OUT"

fail=0
for pat in \
  "kind: Deployment" \
  "kind: Service" \
  "kind: Route" \
  "kind: Secret" \
  "helm.sh/resource-policy: keep" \
  "session_secret:" \
  "apiVersion: cert-manager.io/v1" \
  "kind: Issuer" \
  "kind: Certificate" \
  "name: devspaces-multicluster-redirector-venafi-credentials" \
  "name: devspaces-multicluster-redirector-issuer" \
  "name: devspaces-multicluster-redirector-cert" \
  "zone: \"VED\\\\Policy\\\\Certificates\\\\DevSpaces\"" \
  "url: \"https://tpp.example.com/vedsdk\"" \
  "venafi.cert-manager.io/custom-fields:" \
  "\"name\": \"Technical Owner\"" \
  "\"name\": \"Environment\"" \
  "\"name\": \"Application Name\"" \
  "commonName: \"devspaces-redirector.apps.dc1.example.com\"" \
  "- \"devspaces-redirector.apps.dc1.example.com\"" \
  "- \"devspaces-redirector.example.com\"" \
  "duration: 17520h" \
  "renewBefore: 17448h" \
  "rotationPolicy: Always" \
  "secretName: devspaces-multicluster-redirector-tls" \
  "externalCertificate:" \
  "name: devspaces-multicluster-redirector-tls" \
  "name: devspaces-multicluster-redirector-router-tls" \
  "kind: ConfigMap" \
  "kind: ServiceAccount" \
  "kind: NetworkPolicy" \
  "kind: PodDisruptionBudget" \
  "namespace: devspaces-redirector" \
  "registry.redhat.io/devspaces/multicluster-redirector-rhel9" \
  "ose-oauth-proxy-rhel9@sha256:" \
  "group-mapping.json" \
  "secretName: devspaces-multicluster-redirector-session-secret" \
  "-http-address=:8443" \
  "-https-address=" \
  "-pass-user-headers" \
  "cookie-secret-file=/etc/proxy/secrets/session_secret" \
  "mountPath: /etc/config" \
  "termination: edge" \
  "oauth-redirectreference.primary" \
  "targetPort: 8443" \
  "name: KUBERNETES_REQUEST_TIMEOUT" \
  "value: \"60000\"" \
  "name: KUBERNETES_CONNECTION_TIMEOUT" \
  "value: \"30000\"" \
  "name: JAVA_TOOL_OPTIONS" \
  "--add-opens=java.base/java.nio=ALL-UNNAMED -Dio.netty.tryReflectionSetAccessible=true -Dio.netty.noPreferDirect=true -Dio.netty.maxDirectMemory=268435456" \
  "path: /hello" \
  "path: /oauth/healthz" \
  "allowPrivilegeEscalation: false" \
  "runAsNonRoot: true" \
  "type: RuntimeDefault" \
  "topologySpreadConstraints:"
do
  grep -Fq -- "$pat" "$OUT" || { echo "FAIL missing: $pat"; fail=1; }
done

# Must not render ExternalSecret or VaultStaticSecret CRs from the chart.
if grep -Eq '^kind: (ExternalSecret|VaultStaticSecret)$' "$OUT"; then
  echo "FAIL ExternalSecret/VaultStaticSecret must not render"
  fail=1
fi

# Verify generated session_secret decodes to a 32-char string.
GEN_LEN="$(awk '/session_secret: /{print $2}' "$OUT" | tr -d '"' | base64 -d | wc -c | tr -d ' ')"
if [[ "$GEN_LEN" -lt 32 ]]; then
  echo "FAIL expected >= 32-byte random session_secret, got $GEN_LEN"
  fail=1
fi

# Must not use the lab Python image or in-pod TLS secret for oauth-proxy.
if grep -Fq "devspaces-redirector:python" "$OUT"; then
  echo "FAIL must not render lab Python image"
  fail=1
fi
if grep -Fq "proxy-tls" "$OUT"; then
  echo "FAIL oauth-proxy uses plain HTTP on 8443 (edge TLS on Route)"
  fail=1
fi

# Cluster-scoped RBAC and Namespace stay outside the chart.
if grep -Fq "kind: ClusterRole" "$OUT"; then
  echo "FAIL ClusterRole must not render from the chart (see manifests/)"
  fail=1
fi
if grep -Fq "kind: ClusterRoleBinding" "$OUT"; then
  echo "FAIL ClusterRoleBinding must not render from the chart (see manifests/)"
  fail=1
fi
if grep -Fq "kind: Namespace" "$OUT"; then
  echo "FAIL Namespace must not render from the chart"
  fail=1
fi

RBAC_MANIFEST="$(cd "$CHART/../.." && pwd)/manifests/devspaces-multicluster-redirector/rbac.yaml"
[[ -f "$RBAC_MANIFEST" ]] || { echo "FAIL missing $RBAC_MANIFEST"; fail=1; }
if [[ -f "$RBAC_MANIFEST" ]]; then
  for pat in \
    "kind: ClusterRole" \
    "kind: ClusterRoleBinding" \
    "tokenreviews" \
    "subjectaccessreviews" \
    "user.openshift.io" \
    "name: devspaces-multicluster-redirector" \
    "namespace: devspaces-redirector"
  do
    grep -Fq -- "$pat" "$RBAC_MANIFEST" || { echo "FAIL rbac manifest missing: $pat"; fail=1; }
  done
fi

ARGO_MANIFEST="$(cd "$CHART/../.." && pwd)/argocd/apps/devspaces-multicluster-redirector.yaml"
[[ -f "$ARGO_MANIFEST" ]] || { echo "FAIL missing $ARGO_MANIFEST"; fail=1; }
if [[ -f "$ARGO_MANIFEST" ]]; then
  for pat in \
    "ignoreDifferences:" \
    "/data/session_secret" \
    "RespectIgnoreDifferences=true"
  do
    grep -Fq -- "$pat" "$ARGO_MANIFEST" || { echo "FAIL argocd manifest missing: $pat"; fail=1; }
  done
fi

# Multi-group and comma-separated AND groupMapping rendering.
GRP_OUT="$(mktemp)"
helm template mcr "$CHART" \
  -f "$CHART/values.yaml" \
  --set "groupMapping.cluster-a-devs=https://devspaces.apps.cluster-a.example.com" \
  --set "groupMapping.payments-devs\,pci-cleared=https://devspaces.apps.pci.example.com" \
  --namespace devspaces-redirector >"$GRP_OUT"
for pat in \
  '"cluster-a-devs": "https://devspaces.apps.cluster-a.example.com"' \
  '"payments-devs,pci-cleared": "https://devspaces.apps.pci.example.com"'
do
  grep -Fq -- "$pat" "$GRP_OUT" || { echo "FAIL groupMapping missing: $pat"; fail=1; }
done
rm -f "$GRP_OUT"

# Structured datacenters (dc1 / dc2 URLs + groups list + Pattern B requiredGroup AND logic).
DC_OUT="$(mktemp)"
helm template mcr "$CHART" \
  -f "$CHART/values.yaml" \
  --set "datacenters.dc1.url=https://devspaces.apps.dc1.example.com" \
  --set "datacenters.dc1.requiredGroup=corp_nprd_devspaces_users" \
  --set "datacenters.dc1.groups[0]=corp_nprd_payments_devs" \
  --set "datacenters.dc1.groups[1]=corp_nprd_channels_devs" \
  --set "datacenters.dc2.url=https://devspaces.apps.dc2.example.com" \
  --set "datacenters.dc2.groups[0]=corp_nprd_lending_devs" \
  --namespace devspaces-redirector >"$DC_OUT"
for pat in \
  '"corp_nprd_devspaces_users,corp_nprd_payments_devs": "https://devspaces.apps.dc1.example.com"' \
  '"corp_nprd_devspaces_users,corp_nprd_channels_devs": "https://devspaces.apps.dc1.example.com"' \
  '"corp_nprd_lending_devs": "https://devspaces.apps.dc2.example.com"'
do
  grep -Fq -- "$pat" "$DC_OUT" || { echo "FAIL datacenters rendering missing: $pat"; fail=1; }
done
rm -f "$DC_OUT"

# NetworkPolicy can be disabled.
OFF="$(mktemp)"
helm template mcr "$CHART" \
  -f "$CHART/values.yaml" \
  --set networkPolicy.enabled=false \
  --namespace devspaces-redirector >"$OFF"
if grep -Fq "kind: NetworkPolicy" "$OFF"; then
  echo "FAIL NetworkPolicy must not render when disabled"
  fail=1
fi
rm -f "$OFF"

# Explicit oauth callback URI mode.
URI="$(mktemp)"
helm template mcr "$CHART" \
  -f "$CHART/values.yaml" \
  --set route.oauthRedirectReference=false \
  --set route.host=redirector.apps.example.com \
  --namespace devspaces-redirector >"$URI"
if ! grep -Fq 'oauth-redirecturi.primary: "https://redirector.apps.example.com/oauth/callback"' "$URI"; then
  echo "FAIL expected oauth-redirecturi.primary from route.host"
  fail=1
fi
if grep -Fq "oauth-redirectreference.primary" "$URI"; then
  echo "FAIL redirectreference must not render when oauthRedirectReference=false"
  fail=1
fi
rm -f "$URI"

# oauthRedirectReference=false without host or oauthCallbackUrl must fail at template time.
if helm template mcr "$CHART" \
  -f "$CHART/values.yaml" \
  --set route.oauthRedirectReference=false \
  --set route.host="" \
  --set route.oauthCallbackUrl="" \
  --namespace devspaces-redirector >/dev/null 2>&1; then
  echo "FAIL expected template error when oauthRedirectReference=false and host/callback are empty"
  fail=1
fi

# Invalid groupMapping URL must fail at template time.
if helm template mcr "$CHART" \
  -f "$CHART/values.yaml" \
  --set "groupMapping.developers=not-a-valid-url" \
  --namespace devspaces-redirector >/dev/null 2>&1; then
  echo "FAIL expected template error when groupMapping value is not an http(s) URL"
  fail=1
fi

# oauth-proxy must not float on :latest with IfNotPresent.
if grep -Eq 'ose-oauth-proxy-rhel9:latest' "$OUT"; then
  echo "FAIL oauth-proxy image must be digested, not :latest"
  fail=1
fi
if ! grep -Fq 'Allow all egress' "$OUT"; then
  echo "FAIL NetworkPolicy egress comment must describe allow-all"
  fail=1
fi

# Venafi Certificate: edev omits gslbHostname SAN; non-edev requires gslbHostname.
EDEV_CERT="$(mktemp)"
helm template mcr "$CHART" \
  -f "$CHART/values.yaml" \
  -f "$CHART/values-deploy.yaml" \
  --set environmentName=edev \
  --set venafi.gslbHostname="" \
  --namespace devspaces-redirector >"$EDEV_CERT"
if ! grep -Fq 'commonName: "devspaces-redirector.apps.dc1.example.com"' "$EDEV_CERT"; then
  echo "FAIL edev Certificate missing commonName"
  fail=1
fi
if grep -Fq 'devspaces-redirector.example.com' "$EDEV_CERT"; then
  echo "FAIL edev Certificate must omit gslbHostname SAN"
  fail=1
fi
rm -f "$EDEV_CERT"

if helm template mcr "$CHART" \
  -f "$CHART/values.yaml" \
  -f "$CHART/values-deploy.yaml" \
  --set environmentName=nprd \
  --set venafi.gslbHostname="" \
  --namespace devspaces-redirector >/dev/null 2>&1; then
  echo "FAIL expected template error when environmentName!=edev and venafi.gslbHostname is empty"
  fail=1
fi

# Venafi disabled (base values.yaml or lab Argo override) must not render Issuer, Certificate, or router-tls Role.
NO_CERT="$(mktemp)"
helm template mcr "$CHART" \
  -f "$CHART/values.yaml" \
  --namespace devspaces-redirector >"$NO_CERT"
if grep -Eq '^kind: (Certificate|Issuer)$' "$NO_CERT"; then
  echo "FAIL Issuer/Certificate must not render when venafi.enabled=false"
  fail=1
fi
if grep -Fq "mcr-router-tls" "$NO_CERT"; then
  echo "FAIL router-tls Role/RoleBinding must not render when venafi.enabled=false"
  fail=1
fi
rm -f "$NO_CERT"

# Release-name auto-naming (`helm upgrade --install devspacesmcr . -n devspaces`) + null/minimal venafi sub-fields:
MIN_VENAFI="$(mktemp)"
MIN_VALS="$(mktemp)"
cat >"$MIN_VALS" <<'EOF'
venafi:
  enabled: true
  customFields: null
  annotations: null
  secretTemplate: null
  subject: null
  hostname: redirector.apps.example.com
  zone: "VED\\Policy\\Certificates\\DevSpaces"
  tpp:
    url: https://tpp.example.com/vedsdk
    caBundleSecretRef:
      name: corp-ca-bundle
EOF
helm template devspacesmcr "$CHART" \
  -f "$MIN_VALS" \
  --namespace devspaces >"$MIN_VENAFI"
for pat in \
  "namespace: devspaces" \
  "name: devspacesmcr-venafi-credentials" \
  "name: devspacesmcr-issuer" \
  "caBundleSecretRef:" \
  "name: corp-ca-bundle" \
  "name: devspacesmcr-cert" \
  "\"value\": \"devspacesmcr\"" \
  "commonName: \"redirector.apps.example.com\"" \
  "secretName: devspacesmcr-tls" \
  "name: devspacesmcr-router-tls" \
  "name: devspacesmcr-group-mapping" \
  "name: devspacesmcr-session-secret"
do
  grep -Fq -- "$pat" "$MIN_VENAFI" || { echo "FAIL release-derived render missing: $pat"; fail=1; }
done
rm -f "$MIN_VENAFI" "$MIN_VALS"

if [[ "$fail" -ne 0 ]]; then
  echo "FAIL chart tests"
  exit 1
fi
echo "OK charts/devspaces-multicluster-redirector"
