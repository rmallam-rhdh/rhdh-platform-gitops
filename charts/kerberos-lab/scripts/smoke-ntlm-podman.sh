#!/usr/bin/env bash
# Local system smoke: NTLM corporate parent + cntlm bridge (no cluster required).
# Unit companion: charts/kerberos-lab/tests/test-chart.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="${TAG:-0.2.0}"
NET="kerberos-lab-ntlm-smoke"
CORP="kerberos-lab-corp-ntlm"
BRIDGE="kerberos-lab-bridge-ntlm"
need() { command -v "$1" >/dev/null || { echo "missing $1" >&2; exit 1; }; }
need podman

cleanup() {
  podman rm -f "$BRIDGE" "$CORP" >/dev/null 2>&1 || true
  podman network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> build images"
podman build -t "kerberos-lab-corporate-proxy:${TAG}" -f "$ROOT/images/corporate-proxy/Containerfile" "$ROOT/images/corporate-proxy"
podman build -t "kerberos-lab-bridge:${TAG}" -f "$ROOT/images/bridge/Containerfile" "$ROOT/images/bridge"

cleanup
podman network create "$NET" >/dev/null

ALLOW="$(mktemp)"
printf '%s\n' '.httpbin.org' 'ifconfig.me' >"$ALLOW"

echo "==> start NTLM corporate parent"
podman run -d --name "$CORP" --network "$NET" \
  -e PROXY_AUTH_MODE=ntlm \
  -v "$ALLOW:/etc/squid/allow.txt:ro,Z" \
  "kerberos-lab-corporate-proxy:${TAG}" >/dev/null

echo "==> wait for corporate :3128"
for i in $(seq 1 30); do
  if podman exec "$CORP" bash -c 'echo >/dev/tcp/127.0.0.1/3128' 2>/dev/null; then
    break
  fi
  sleep 1
  [[ "$i" -eq 30 ]] && { echo "FAIL corporate not listening"; podman logs "$CORP" | tail -40; exit 1; }
done

echo "==> start cntlm bridge"
podman run -d --name "$BRIDGE" --network "$NET" \
  -e PROXY_AUTH_MODE=ntlm \
  -e CORPORATE_PROXY_HOSTNAME="$CORP" \
  -e CORPORATE_PROXY_PORT=3128 \
  -e NTLM_USERNAME=labntlm \
  -e NTLM_PASSWORD=labntlm-pass \
  -e NTLM_DOMAIN=LAB \
  "kerberos-lab-bridge:${TAG}" >/dev/null

echo "==> wait for bridge :3128"
for i in $(seq 1 30); do
  if podman exec "$BRIDGE" bash -c 'echo >/dev/tcp/127.0.0.1/3128' 2>/dev/null; then
    break
  fi
  sleep 1
  [[ "$i" -eq 30 ]] && { echo "FAIL bridge not listening"; podman logs "$BRIDGE" | tail -40; exit 1; }
done

echo "==> direct to corporate without auth must be 407 (HTTP probe)"
# HTTPS CONNECT can fail closed before returning 407 depending on curl/squid timing;
# plain HTTP reliably surfaces Proxy-Authenticate: NTLM.
code="$(podman run --rm --network "$NET" curlimages/curl:8.5.0 \
  -s -o /dev/null -w '%{http_code}' \
  -x "http://${CORP}:3128" --connect-timeout 10 \
  http://example.com/ || true)"
if [[ "$code" != "407" ]]; then
  echo "FAIL expected 407 from corporate, got ${code}"
  podman logs "$CORP" | tail -30
  exit 1
fi
hdr="$(podman run --rm --network "$NET" curlimages/curl:8.5.0 \
  -s -D - -o /dev/null -x "http://${CORP}:3128" --connect-timeout 10 \
  http://example.com/ || true)"
echo "$hdr" | grep -qi 'Proxy-Authenticate:.*NTLM' \
  || { echo "FAIL missing Proxy-Authenticate: NTLM"; echo "$hdr"; exit 1; }
echo "OK  corporate NTLM challenge (${code})"

echo "==> via bridge (cntlm) must be 200"
code="$(podman exec "$BRIDGE" bash -c \
  'curl -s -o /dev/null -w "%{http_code}" -x http://127.0.0.1:3128 --connect-timeout 20 https://httpbin.org/get' || true)"
if [[ "$code" != "200" ]]; then
  echo "FAIL expected 200 via bridge, got ${code}"
  podman logs "$BRIDGE" | tail -40
  podman logs "$CORP" | tail -40
  exit 1
fi
echo "OK  bridge NTLM path (${code})"
echo "RESULT: OK"
rm -f "$ALLOW"
