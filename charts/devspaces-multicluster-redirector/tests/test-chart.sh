#!/usr/bin/env bash
# Unit + render checks for the multicluster redirector chart.
set -euo pipefail
CHART="$(cd "$(dirname "$0")/.." && pwd)"
helm lint "$CHART"
helm lint "$CHART" -f "$CHART/values.yaml" -f "$CHART/values-deploy.yaml"

OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT

# Default customer render (values.yaml + values-deploy.yaml) pulls session + Venafi
# secrets from HashiCorp Vault via VaultStaticSecret and names all resources after .Release.Name.
helm template devspaces-multicluster-redirector "$CHART" \
  -f "$CHART/values.yaml" \
  -f "$CHART/values-deploy.yaml" \
  --namespace devspaces-redirector >"$OUT"

fail=0
for pat in \
  "kind: Deployment" \
  "kind: Service" \
  "kind: Route" \
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
  "apiVersion: secrets.hashicorp.com/v1beta1" \
  "kind: VaultStaticSecret" \
  "kind: ServiceAccount" \
  "kind: NetworkPolicy" \
  "kind: PodDisruptionBudget" \
  "namespace: devspaces-redirector" \
  "registry.redhat.io/devspaces/multicluster-redirector-rhel9" \
  "ose-oauth-proxy-rhel9@sha256:" \
  "group-mapping.json" \
  "mount: \"secrets\"" \
  "path: \"devspaces-redirector/session\"" \
  "vaultAuthRef: \"default\"" \
  "rolloutRestartTargets:" \
  "create: true" \
  "secretName: devspaces-multicluster-redirector-session-secret" \
  "-http-address=:8443" \
  "-https-address=" \
  "-pass-user-headers" \
  "cookie-secret-file=/etc/proxy/secrets/session_secret" \
  "mountPath: /etc/config" \
  "termination: edge" \
  "oauth-redirectreference.primary" \
  "targetPort: 8443" \
  "path: /hello" \
  "path: /oauth/healthz" \
  "allowPrivilegeEscalation: false" \
  "runAsNonRoot: true" \
  "type: RuntimeDefault" \
  "topologySpreadConstraints:"
do
  grep -Fq -- "$pat" "$OUT" || { echo "FAIL missing: $pat"; fail=1; }
done

# Default vaultStaticSecret mode must not render a raw Secret or ExternalSecret.
if grep -Eq '^kind: Secret$' "$OUT"; then
  echo "FAIL raw Secret must not render when sessionSecret.mode=vaultStaticSecret"
  fail=1
fi
if grep -Eq '^kind: ExternalSecret$' "$OUT"; then
  echo "FAIL ExternalSecret must not render when sessionSecret.mode=vaultStaticSecret"
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

# VaultStaticSecret advanced options (Vault Enterprise namespace, custom secretKey, destinationSecretName).
VSS_ADV="$(mktemp)"
helm template mcr "$CHART" \
  -f "$CHART/values.yaml" \
  --set sessionSecret.mode=vaultStaticSecret \
  --set sessionSecret.secretKey=cookie_secret \
  --set sessionSecret.vaultStaticSecret.vaultNamespace=admin/platform \
  --set sessionSecret.vaultStaticSecret.destinationSecretName=custom-vso-session \
  --set sessionSecret.vaultStaticSecret.version=2 \
  --namespace devspaces-redirector >"$VSS_ADV"
for pat in \
  'namespace: "admin/platform"' \
  'version: 2' \
  'name: custom-vso-session' \
  'secretName: custom-vso-session' \
  'cookie-secret-file=/etc/proxy/secrets/cookie_secret'
do
  grep -Fq -- "$pat" "$VSS_ADV" || { echo "FAIL VaultStaticSecret advanced missing: $pat"; fail=1; }
done
rm -f "$VSS_ADV"

# VaultStaticSecret validation failures.
if helm template mcr "$CHART" \
  -f "$CHART/values.yaml" \
  --set sessionSecret.mode=vaultStaticSecret \
  --set sessionSecret.vaultStaticSecret.mount="" \
  --namespace devspaces-redirector >/dev/null 2>&1; then
  echo "FAIL expected template error when vaultStaticSecret.mount is empty"
  fail=1
fi
if helm template mcr "$CHART" \
  -f "$CHART/values.yaml" \
  --set sessionSecret.mode=vaultStaticSecret \
  --set sessionSecret.vaultStaticSecret.path="" \
  --namespace devspaces-redirector >/dev/null 2>&1; then
  echo "FAIL expected template error when vaultStaticSecret.path is empty"
  fail=1
fi
if helm template mcr "$CHART" \
  -f "$CHART/values.yaml" \
  --set sessionSecret.mode=vaultStaticSecret \
  --set sessionSecret.vaultStaticSecret.type=kv-v3 \
  --namespace devspaces-redirector >/dev/null 2>&1; then
  echo "FAIL expected template error when vaultStaticSecret.type is invalid"
  fail=1
fi
if helm template mcr "$CHART" \
  -f "$CHART/values.yaml" \
  --set sessionSecret.mode=vaultStaticSecret \
  --set sessionSecret.vaultStaticSecret.rolloutRestart=true \
  --set sessionSecret.vaultStaticSecret.hmacSecretData=false \
  --namespace devspaces-redirector >/dev/null 2>&1; then
  echo "FAIL expected template error when rolloutRestart=true and hmacSecretData=false"
  fail=1
fi

# ESO mode (ExternalSecret from Vault).
ESO_OUT="$(mktemp)"
helm template mcr "$CHART" \
  -f "$CHART/values.yaml" \
  --set sessionSecret.mode=eso \
  --namespace devspaces-redirector >"$ESO_OUT"
for pat in \
  "apiVersion: external-secrets.io/v1" \
  "kind: ExternalSecret" \
  "name: vault-secret-store" \
  "key: devspaces-redirector/session" \
  "property: session_secret"
do
  grep -Fq -- "$pat" "$ESO_OUT" || { echo "FAIL ESO mode missing: $pat"; fail=1; }
done
if grep -Eq '^kind: (Secret|VaultStaticSecret)$' "$ESO_OUT"; then
  echo "FAIL Secret/VaultStaticSecret must not render when sessionSecret.mode=eso"
  fail=1
fi
rm -f "$ESO_OUT"

# Multi-group and comma-separated AND groupMapping rendering.
GRP_OUT="$(mktemp)"
helm template mcr "$CHART" \
  -f "$CHART/values.yaml" \
  --set "groupMapping.cluster-a-devs=https://devspaces.apps.cluster-a.example.com" \
  --set "groupMapping.payments-devs\,pci-cleared=https://devspaces.apps.pci.example.com" \
  --namespace devspaces-redirector >"$GRP_OUT"
for pat in \
  '"cluster-a-devs":"https://devspaces.apps.cluster-a.example.com"' \
  '"payments-devs,pci-cleared":"https://devspaces.apps.pci.example.com"'
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
  '"corp_nprd_devspaces_users,corp_nprd_payments_devs":"https://devspaces.apps.dc1.example.com"' \
  '"corp_nprd_devspaces_users,corp_nprd_channels_devs":"https://devspaces.apps.dc1.example.com"' \
  '"corp_nprd_lending_devs":"https://devspaces.apps.dc2.example.com"'
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

# Standalone lab Secret mode + short sessionSecret.value (< 16 chars) validation.
SEC_OUT="$(mktemp)"
helm template mcr "$CHART" \
  -f "$CHART/values.yaml" \
  --set sessionSecret.mode=secret \
  --set sessionSecret.value=test-session-secret-32charsxx \
  --namespace devspaces-redirector >"$SEC_OUT"
if ! grep -Eq '^kind: Secret$' "$SEC_OUT"; then
  echo "FAIL expected kind: Secret when sessionSecret.mode=secret"
  fail=1
fi
if grep -Eq '^kind: (VaultStaticSecret|ExternalSecret)$' "$SEC_OUT"; then
  echo "FAIL Vault CRs must not render when sessionSecret.mode=secret"
  fail=1
fi
rm -f "$SEC_OUT"

if helm template mcr "$CHART" \
  -f "$CHART/values.yaml" \
  --set sessionSecret.mode=secret \
  --set sessionSecret.value=too-short \
  --namespace devspaces-redirector >/dev/null 2>&1; then
  echo "FAIL expected template error when sessionSecret.value is < 16 chars"
  fail=1
fi

# Existing session secret path (both mode=external and legacy create=false).
for extra_flag in "--set sessionSecret.mode=external" "--set sessionSecret.create=false"; do
  EXT="$(mktemp)"
  # shellcheck disable=SC2086
  helm template mcr "$CHART" \
    -f "$CHART/values.yaml" \
    $extra_flag \
    --set sessionSecret.existingSecret=my-session \
    --namespace devspaces-redirector >"$EXT"
  if grep -Eq '^kind: (Secret|VaultStaticSecret|ExternalSecret)$' "$EXT"; then
    echo "FAIL no secret CR should render for $extra_flag"
    fail=1
  fi
  if ! grep -Fq "secretName: my-session" "$EXT"; then
    echo "FAIL deployment must mount existingSecret for $extra_flag"
    fail=1
  fi
  rm -f "$EXT"
done

# mode=external or create=false without existingSecret must fail at template time.
if helm template mcr "$CHART" \
  -f "$CHART/values.yaml" \
  --set sessionSecret.create=false \
  --set sessionSecret.existingSecret="" \
  --namespace devspaces-redirector >/dev/null 2>&1; then
  echo "FAIL expected template error when existingSecret is empty"
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
# Every resource, Issuer, Certificate, and Secret must derive from `.Release.Name` (`devspacesmcr`) and `.Release.Namespace` (`devspaces`).
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
  credentialsSecret:
    mode: secret
    accessToken: test-venafi-access-token
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
