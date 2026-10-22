#!/usr/bin/env bash
# Used by kubelet probes. Fail if Squid is down on loopback OR the TGT is missing/expired.
set -euo pipefail
PORT="${1:-3128}"
export KRB5_CONFIG="${KRB5_CONFIG:-/tmp/krb5.conf}"
export KRB5CCNAME="${KRB5CCNAME:-FILE:/tmp/krb5cc_bridge}"
export KRB5_KTNAME="${KRB5_KTNAME:-/keytabs/bridge-client.keytab}"

# Loopback only — never probe the pod IP.
bash -c "echo >/dev/tcp/127.0.0.1/${PORT}"

# Ticket must be present and not expired (Negotiate needs a valid TGT).
klist -s
