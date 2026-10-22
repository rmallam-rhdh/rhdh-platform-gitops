#!/usr/bin/env bash
set -euo pipefail

REALM="${REALM:-LAB.LOCAL}"
KDC_HOST="${KDC_HOSTNAME:-kdc.kerberos-lab.svc.cluster.local}"
CORP="${CORPORATE_PROXY_HOSTNAME:-corporate-proxy.kerberos-lab.svc.cluster.local}"
CORP_PORT="${CORPORATE_PROXY_PORT:-3128}"
CLIENT_PRINC="${BRIDGE_CLIENT_PRINCIPAL:-rhdh-bridge@${REALM}}"
KTNAME="${KRB5_KTNAME:-/keytabs/bridge-client.keytab}"

mkdir -p /tmp/squid

cat >/tmp/krb5.conf <<EOF
[libdefaults]
  default_realm = ${REALM}
  dns_lookup_realm = false
  dns_lookup_kdc = false
  rdns = false
  forwardable = true

[realms]
  ${REALM} = {
    kdc = ${KDC_HOST}
    admin_server = ${KDC_HOST}
  }
EOF
export KRB5_CONFIG=/tmp/krb5.conf
export KRB5_KTNAME="$KTNAME"

if [[ ! -f "$KTNAME" ]]; then
  echo "ERROR: keytab missing at ${KTNAME}" >&2
  exit 1
fi

# Wait for lab KDC (sidecar may start before corporate/KDC are ready).
for i in $(seq 1 60); do
  if kinit -kt "$KTNAME" "$CLIENT_PRINC" 2>/tmp/kinit.err; then
    break
  fi
  echo "waiting for KDC (${i}/60): $(cat /tmp/kinit.err 2>/dev/null || true)"
  sleep 5
  if [[ "$i" -eq 60 ]]; then
    echo "ERROR: kinit failed after retries" >&2
    cat /tmp/kinit.err >&2 || true
    exit 1
  fi
done

(
  while true; do
    sleep 21600
    kinit -kt "$KTNAME" "$CLIENT_PRINC" || true
  done
) &

sed \
  -e "s|__CORP_HOST__|${CORP}|g" \
  -e "s|__CORP_PORT__|${CORP_PORT}|g" \
  /etc/squid/squid.conf.template >/tmp/squid.conf

rm -f /tmp/squid/squid.pid
exec /usr/sbin/squid -N -f /tmp/squid.conf
