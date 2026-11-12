#!/usr/bin/env bash
# Unit + render checks for the multicluster redirector chart.
set -euo pipefail
CHART="$(cd "$(dirname "$0")/.." && pwd)"
helm lint "$CHART"

OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT

helm template mcr "$CHART" \
  -f "$CHART/values.yaml" \
  -f "$CHART/values-deploy.yaml" \
  --set sessionSecret.value=test-session-secret-32charsxx \
  --namespace devspaces-redirector >"$OUT"

fail=0
for pat in \
  "kind: Deployment" \
  "kind: Service" \
  "kind: Route" \
  "kind: ConfigMap" \
  "kind: Secret" \
  "kind: ServiceAccount" \
  "kind: NetworkPolicy" \
  "namespace: devspaces-redirector" \
  "registry.redhat.io/devspaces/multicluster-redirector-rhel9" \
  "ose-oauth-proxy-rhel9@sha256:" \
  "group-mapping.json" \
  "session_secret" \
  "-http-address=:8443" \
  "-https-address=" \
  "-pass-user-headers" \
  "cookie-secret-file=/etc/proxy/secrets/session_secret" \
  "mountPath: /etc/config" \
  "termination: edge" \
  "oauth-redirectreference.primary" \
  "targetPort: 8443"
do
  grep -Fq -- "$pat" "$OUT" || { echo "FAIL missing: $pat"; fail=1; }
done

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

# NetworkPolicy can be disabled.
OFF="$(mktemp)"
helm template mcr "$CHART" \
  -f "$CHART/values.yaml" \
  --set networkPolicy.enabled=false \
  --set sessionSecret.value=test-session-secret-32charsxx \
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
  --set sessionSecret.value=test-session-secret-32charsxx \
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

# Existing session secret path.
EXT="$(mktemp)"
helm template mcr "$CHART" \
  -f "$CHART/values.yaml" \
  --set sessionSecret.create=false \
  --set sessionSecret.existingSecret=my-session \
  --namespace devspaces-redirector >"$EXT"
if grep -Fq "kind: Secret" "$EXT"; then
  echo "FAIL Secret must not render when sessionSecret.create=false"
  fail=1
fi
if ! grep -Fq "secretName: my-session" "$EXT"; then
  echo "FAIL deployment must mount existingSecret"
  fail=1
fi
rm -f "$EXT"

# create=false without existingSecret must fail at template time.
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

if [[ "$fail" -ne 0 ]]; then
  echo "FAIL chart tests"
  exit 1
fi
echo "OK charts/devspaces-multicluster-redirector"
