#!/usr/bin/env bash
# Used by optional probes. Loopback listen must be up.
# Kerberos mode also requires a live TGT; NTLM mode skips klist.
set -euo pipefail
PORT="${1:-3128}"
MODE="$(echo "${PROXY_AUTH_MODE:-kerberos}" | tr '[:upper:]' '[:lower:]')"

# Loopback only — never probe the pod IP.
bash -c "echo >/dev/tcp/127.0.0.1/${PORT}"

case "$MODE" in
  ntlm)
    # cntlm is up if the listen port answered.
    exit 0
    ;;
  *)
    export KRB5_CONFIG="${KRB5_CONFIG:-/tmp/krb5.conf}"
    export KRB5CCNAME="${KRB5CCNAME:-FILE:/tmp/krb5cc_bridge}"
    export KRB5_KTNAME="${KRB5_KTNAME:-/keytabs/bridge-client.keytab}"
    klist -s
    ;;
esac
