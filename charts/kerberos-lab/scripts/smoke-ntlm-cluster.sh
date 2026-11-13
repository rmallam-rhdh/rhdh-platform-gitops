#!/usr/bin/env bash
# Cluster smoke: NTLM corporate-proxy + standalone cntlm bridge (no Hub required).
set -euo pipefail
NS_LAB="${NS_LAB:-kerberos-lab}"
TARGET="${TARGET:-https://httpbin.org/get}"

need() { command -v "$1" >/dev/null || { echo "missing $1" >&2; exit 1; }; }
need oc

echo "==> lab pods"
oc -n "$NS_LAB" get pods -o wide

echo "==> wait for corporate-proxy + bridge Ready"
oc -n "$NS_LAB" rollout status deploy/corporate-proxy --timeout=180s
oc -n "$NS_LAB" rollout status deploy/bridge --timeout=180s

http_code_from_oc_run() {
  # oc run -i mixes prompts/delete noise with curl -w output; keep last 3-digit code.
  printf '%s' "$1" | grep -Eo '[0-9]{3}' | tail -1
}

echo "==> direct to corporate without auth must be 407"
raw="$(oc -n "$NS_LAB" run ntlm-corp-probe --rm -i --restart=Never --image=curlimages/curl:8.5.0 -- \
  curl -s -o /dev/null -w '%{http_code}' -x "http://corporate-proxy.${NS_LAB}.svc.cluster.local:3128" \
  --connect-timeout 15 http://example.com/ 2>&1 || true)"
code="$(http_code_from_oc_run "$raw")"
if [[ "$code" != "407" ]]; then
  echo "FAIL expected 407 from corporate, got '${code}' (raw=${raw})"
  oc -n "$NS_LAB" logs deploy/corporate-proxy --tail=40 || true
  exit 1
fi
echo "OK  corporate NTLM challenge (${code})"

echo "==> via bridge Service must be 200 (${TARGET})"
raw="$(oc -n "$NS_LAB" run ntlm-bridge-probe --rm -i --restart=Never --image=curlimages/curl:8.5.0 -- \
  curl -s -o /dev/null -w '%{http_code}' -x "http://bridge.${NS_LAB}.svc.cluster.local:3128" \
  --connect-timeout 30 "$TARGET" 2>&1 || true)"
code="$(http_code_from_oc_run "$raw")"
if [[ "$code" != "200" ]]; then
  echo "FAIL expected 200 via bridge, got '${code}' (raw=${raw})"
  oc -n "$NS_LAB" logs deploy/bridge --tail=50 || true
  oc -n "$NS_LAB" logs deploy/corporate-proxy --tail=50 || true
  exit 1
fi
echo "OK  bridge NTLM path (${code})"
echo "RESULT: OK"
