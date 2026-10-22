#!/usr/bin/env bash
set -euo pipefail

REALM="${REALM:-LAB.LOCAL}"
KDC_HOST="${KDC_HOSTNAME:-kdc.kerberos-lab.svc.cluster.local}"
CORP="${CORPORATE_PROXY_HOSTNAME:-corporate-proxy.kerberos-lab.svc.cluster.local}"
CORP_PORT="${CORPORATE_PROXY_PORT:-3128}"
CLIENT_PRINC="${BRIDGE_CLIENT_PRINCIPAL:-rhdh-bridge@${REALM}}"

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
export KRB5_KTNAME="${KRB5_KTNAME:-/keytabs/bridge-client.keytab}"

# Obtain / renew a TGT for Squid's Negotiate parent login
kinit -kt "$KRB5_KTNAME" "$CLIENT_PRINC"
(
  while true; do
    sleep 21600
    kinit -kt "$KRB5_KTNAME" "$CLIENT_PRINC" || true
  done
) &

sed \
  -e "s|__CORP_HOST__|${CORP}|g" \
  -e "s|__CORP_PORT__|${CORP_PORT}|g" \
  /etc/squid/squid.conf.template >/tmp/squid.conf

# No disk cache in this lab — skip squid -z (it can leave a PID that breaks -N).
rm -f /var/run/squid/squid.pid
exec squid -N -f /tmp/squid.conf
