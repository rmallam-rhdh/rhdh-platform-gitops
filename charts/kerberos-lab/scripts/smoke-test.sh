#!/usr/bin/env bash
# Smoke: Negotiate path via Hub sidecar localhost proxy (or standalone bridge).
set -euo pipefail
NS_LAB="${NS_LAB:-kerberos-lab}"
NS_HUB="${NS_HUB:-rhdh-kerberos}"
TARGET="${TARGET:-https://example.com}"

need() { command -v "$1" >/dev/null || { echo "missing $1" >&2; exit 1; }; }
need oc

echo "==> lab pods"
oc -n "$NS_LAB" get pods -l app.kubernetes.io/name=kerberos-lab -o wide || oc -n "$NS_LAB" get pods

if oc -n "$NS_HUB" get deploy -l app.kubernetes.io/name=backstage -o name 2>/dev/null | grep -q .; then
  DEPLOY="$(oc -n "$NS_HUB" get deploy -o name | grep -E 'backstage|developer-hub' | head -1)"
  echo "==> Hub sidecar + fetch via HTTP_PROXY (${DEPLOY})"
  oc -n "$NS_HUB" get pod -l app.kubernetes.io/name=backstage -o jsonpath='{range .items[*]}{.metadata.name}{" containers="}{range .spec.containers[*]}{.name}{","}{end}{"\n"}{end}' || true
  oc -n "$NS_HUB" exec "$DEPLOY" -c backstage-backend -- \
    sh -c "echo HTTPS_PROXY=\$HTTPS_PROXY; node --use-env-proxy -e \"fetch('${TARGET}').then(r=>console.log('status',r.status)).catch(e=>{console.error(e); process.exit(1)})\""
  echo "OK sidecar path"
  exit 0
fi

# Fallback: curl Job against standalone bridge Service
echo "==> no Hub deploy; trying standalone bridge Service"
oc -n "$NS_LAB" run kerberos-smoke --rm -i --restart=Never --image=curlimages/curl:8.5.0 -- \
  --env=HTTP_PROXY=http://bridge.${NS_LAB}.svc.cluster.local:3128 \
  --env=HTTPS_PROXY=http://bridge.${NS_LAB}.svc.cluster.local:3128 \
  -- curl -fsS -o /dev/null -w "%{http_code}\n" "$TARGET"
