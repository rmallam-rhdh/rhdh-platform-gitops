#!/usr/bin/env bash
set -euo pipefail

REALM="${REALM:-LAB.LOCAL}"
CORP_HOST="${CORPORATE_PROXY_HOSTNAME:-corporate-proxy.kerberos-lab.svc.cluster.local}"
KDC_HOST="${KDC_HOSTNAME:-kdc.kerberos-lab.svc.cluster.local}"
HELPER="${NEGOTIATE_HELPER:-/usr/lib/squid/negotiate_kerberos_auth}"
ALLOW_FILE="${ALLOW_FILE:-/etc/squid/allow.txt}"

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
export KRB5_KTNAME="${KRB5_KTNAME:-/keytabs/corporate.keytab}"

# Build squid.conf from template + allow list
ALLOW_ACL=""
if [[ -f "$ALLOW_FILE" ]]; then
  while IFS= read -r host || [[ -n "$host" ]]; do
    [[ -z "$host" || "$host" =~ ^# ]] && continue
    ALLOW_ACL+="acl lab_dst dstdomain ${host}"$'\n'
  done <"$ALLOW_FILE"
fi

sed \
  -e "s|__NEGOTIATE_HELPER__|${HELPER}|g" \
  -e "s|__HTTP_SPN__|HTTP/${CORP_HOST}@${REALM}|g" \
  /etc/squid/squid.conf.template >/tmp/squid.conf

# Insert allow ACL lines before the marker
awk -v acl="$ALLOW_ACL" '
  /__ALLOW_ACL__/ { printf "%s", acl; next }
  { print }
' /tmp/squid.conf >/tmp/squid.conf.final

# No disk cache in this lab — skip squid -z (it can leave a PID that breaks -N).
rm -f /var/run/squid/squid.pid
exec squid -N -f /tmp/squid.conf.final
