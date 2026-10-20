#!/usr/bin/env bash
# System smoke: Hub (or curl pod) reaches the internet via bridge → Negotiate corporate proxy.
set -euo pipefail
NS_LAB="${NS_LAB:-kerberos-lab}"
NS_HUB="${NS_HUB:-rhdh-kerberos}"

echo "==> lab pods"
oc -n "$NS_LAB" get pods,svc,pvc

echo "==> bridge TCP"
oc -n "$NS_LAB" exec deploy/bridge -- bash -c 'true'

echo "==> curl via bridge from a throwaway pod in rhdh-kerberos (expects Negotiate path)"
oc -n "$NS_HUB" delete pod krb-smoke --ignore-not-found --wait=true
# UBI minimal already has curl on many tags; avoid microdnf (repomd is not on the lab allow list).
oc -n "$NS_HUB" run krb-smoke --restart=Never \
  --image=curlimages/curl:8.10.1 \
  --env=HTTP_PROXY=http://bridge.${NS_LAB}.svc.cluster.local:3128 \
  --env=HTTPS_PROXY=http://bridge.${NS_LAB}.svc.cluster.local:3128 \
  --command -- curl -fsS -o /dev/null -w "%{http_code}\n" --connect-timeout 20 https://example.com/
oc -n "$NS_HUB" wait --for=jsonpath='{.status.phase}'=Succeeded pod/krb-smoke --timeout=120s
oc -n "$NS_HUB" logs krb-smoke
oc -n "$NS_HUB" delete pod krb-smoke --ignore-not-found

echo "==> corporate-proxy access log (should show Negotiate / TCP_TUNNEL)"
oc -n "$NS_LAB" logs deploy/corporate-proxy --tail=20 || true
echo "SMOKE OK"
