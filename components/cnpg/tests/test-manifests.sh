#!/usr/bin/env bash
# Unit: kustomize renders the Certified CNPG operator Subscription.
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT

oc kustomize "$DIR/base" >"$OUT" || { echo "FAIL kustomize cnpg"; exit 1; }

need() {
  if grep -q "$1" "$OUT"; then
    echo "OK  $1"
  else
    echo "FAIL missing $1"
    fail=1
  fi
}

need "kind: Namespace"
need "name: cnpg-system"
need "kind: OperatorGroup"
need "kind: Subscription"
need "name: cloudnative-pg"
need "channel: stable-v1"
need "source: certified-operators"

if [ "$fail" -ne 0 ]; then
  echo "CNPG manifest tests failed"
  exit 1
fi
echo "CNPG manifest tests passed"
