#!/usr/bin/env bash
set -euo pipefail
CHART="$(cd "$(dirname "$0")/.." && pwd)"
helm lint "$CHART"
OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT
helm template squid "$CHART" --namespace squid >"$OUT"
fail=0
need() {
  grep -q -e "$1" "$OUT" || { echo "FAIL missing $1"; fail=1; }
}
forbid() {
  if grep -q -e "$1" "$OUT"; then
    echo "FAIL must not contain $1"
    fail=1
  fi
}
need "kind: Deployment"
need "kind: Service"
need "type: ClusterIP"
need "auth_param basic program"
need "proxy_auth REQUIRED"
need "http_access allow authenticated saas"
need "http_access deny all"
need ".service-now.com"
need "mallamrakeshkumar.atlassian.net"
need "system:openshift:scc:anyuid"
need "squid/htpasswd"
need "kubernetes.io/metadata.name: rhdh"
forbid "kind: Route"
forbid "kind: Subscription"
forbid "kind: OperatorGroup"
forbid "istio.io/dataplane-mode"
forbid '\$apr1\$'
forbid "http_access allow localnet"
if grep -q "dstdomain .*\.svc" "$OUT"; then
  echo "FAIL allowlist must not include .svc"
  fail=1
fi
[ "$fail" -eq 0 ] || exit 1
echo "Squid chart tests passed"
