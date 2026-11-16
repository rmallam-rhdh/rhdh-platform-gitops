#!/usr/bin/env bash
set -euo pipefail
CHART="$(cd "$(dirname "$0")/.." && pwd)"
helm lint "$CHART"
OUT="$(mktemp)"
DR="$(mktemp)"
TLS="$(mktemp)"
trap 'rm -f "$OUT" "$DR" "$TLS"' EXIT
helm template cnpg "$CHART" --namespace rhdh >"$OUT"
helm template cnpg-dr "$CHART" -f "$CHART/values-dr.yaml" --namespace rhdh-dr >"$DR"
helm template cnpg-tls "$CHART" -f "$CHART/values-venafi-tls-lab.yaml" --namespace rhdh-cnpg-tls-test >"$TLS"
fail=0
for pat in "kind: Cluster" "name: rhdh-pg" "kind: Namespace" "instances: 3"; do
  grep -q "$pat" "$OUT" || { echo "FAIL primary $pat"; fail=1; }
done
if grep -q "name: rhdh-pg-dr" "$OUT"; then
  echo "FAIL primary rendered the DR cluster name"
  fail=1
fi
for pat in "name: rhdh-dr" "name: rhdh-pg-dr" "instances: 3"; do
  grep -q "$pat" "$DR" || { echo "FAIL dr $pat"; fail=1; }
done
if grep -qE "kind: Subscription|kind: OperatorGroup" "$OUT" "$DR"; then
  echo "FAIL operator install must not be rendered"
  fail=1
fi
if grep -q "istio.io/dataplane-mode: ambient" "$OUT" "$DR"; then
  echo "FAIL CNPG namespaces must stay off ambient"
  fail=1
fi
if grep -q "istio.io/dataplane-mode: none" "$OUT" && grep -q "istio.io/dataplane-mode: none" "$DR" && grep -q "istio.io/dataplane-mode: none" "$TLS"; then
  echo "OK  CNPG namespaces stamp dataplane-mode none"
else
  echo "FAIL CNPG Namespace missing dataplane-mode none"
  fail=1
fi
for pat in \
  "kind: Certificate" \
  "isCA: false" \
  "serverTLSSecret: \"cnpg-server-tls\"" \
  "replicationTLSSecret: \"cnpg-replication-tls\"" \
  "serverCASecret: \"enterprise-ca-chain\"" \
  "clientCASecret: \"enterprise-ca-chain\"" \
  "cnpg.io/reload: \"true\"" \
  "cnpg_streaming_replica"
do
  grep -Fq "$pat" "$TLS" || { echo "FAIL tls overlay missing $pat"; fail=1; }
done
if grep -q "kind: Secret" "$OUT" "$DR" "$TLS"; then
  echo "FAIL CNPG chart must never render Secret objects in Git"
  fail=1
fi
[ "$fail" -eq 0 ] || exit 1
echo "CNPG chart tests passed"
