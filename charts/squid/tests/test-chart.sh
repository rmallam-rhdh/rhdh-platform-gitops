#!/usr/bin/env bash
set -euo pipefail
CHART="$(cd "$(dirname "$0")/.." && pwd)"
helm lint "$CHART"
OUT="$(mktemp)"
ESO="$(mktemp)"
PLACEHOLDER="$(mktemp)"
trap 'rm -f "$OUT" "$ESO" "$PLACEHOLDER"' EXIT
helm template squid "$CHART" --namespace squid >"$OUT"
helm template squid "$CHART" --namespace squid --set secrets.mode=eso >"$ESO"
helm template squid "$CHART" --namespace squid --set secrets.mode=placeholder >"$PLACEHOLDER"
fail=0
need() {
  grep -q -e "$1" "$2" || { echo "FAIL missing $1 in $(basename "$2")"; fail=1; }
}
forbid() {
  if grep -q -e "$1" "$2"; then
    echo "FAIL $(basename "$2") must not contain $1"
    fail=1
  fi
}
need "kind: Deployment" "$OUT"
need "kind: Service" "$OUT"
need "type: ClusterIP" "$OUT"
need "auth_param basic program" "$OUT"
need "proxy_auth REQUIRED" "$OUT"
need "http_access allow authenticated saas" "$OUT"
need "http_access deny all" "$OUT"
need ".service-now.com" "$OUT"
need ".github.com" "$OUT"
need "codeload.github.com" "$OUT"
need ".githubusercontent.com" "$OUT"
need "mallamrakeshkumar.atlassian.net" "$OUT"
need "system:openshift:scc:anyuid" "$OUT"
need "kubernetes.io/metadata.name: rhdh" "$OUT"
forbid "kind: ExternalSecret" "$OUT"
forbid "kind: Route" "$OUT"
forbid "kind: Subscription" "$OUT"
forbid "kind: OperatorGroup" "$OUT"
forbid "istio.io/dataplane-mode" "$OUT"
forbid '\$apr1\$' "$OUT"
forbid "http_access allow localnet" "$OUT"
need "kind: ExternalSecret" "$ESO"
need "squid/htpasswd" "$ESO"
need "kind: Secret" "$PLACEHOLDER"
forbid "kind: ExternalSecret" "$PLACEHOLDER"
if grep -q "dstdomain .*\.svc" "$OUT"; then
  echo "FAIL allowlist must not include .svc"
  fail=1
fi
[ "$fail" -eq 0 ] || exit 1
echo "Squid chart tests passed"
