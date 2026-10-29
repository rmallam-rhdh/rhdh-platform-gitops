#!/usr/bin/env bash
set -euo pipefail

# PROXY_AUTH_MODE=negotiate (default) | ntlm
MODE="$(echo "${PROXY_AUTH_MODE:-negotiate}" | tr '[:upper:]' '[:lower:]')"
REALM="${REALM:-LAB.LOCAL}"
CORP_HOST="${CORPORATE_PROXY_HOSTNAME:-corporate-proxy.kerberos-lab.svc.cluster.local}"
KDC_HOST="${KDC_HOSTNAME:-kdc.kerberos-lab.svc.cluster.local}"
NEGOTIATE_HELPER="${NEGOTIATE_HELPER:-/usr/lib/squid/negotiate_kerberos_auth}"
# Ubuntu Squid 6 ships ntlm_fake_auth (older docs say ntlm_smb_lm_fake).
NTLM_HELPER="${NTLM_HELPER:-/usr/lib/squid/ntlm_fake_auth}"
ALLOW_FILE="${ALLOW_FILE:-/etc/squid/allow.txt}"

ALLOW_ACL=""
if [[ -f "$ALLOW_FILE" ]]; then
  while IFS= read -r host || [[ -n "$host" ]]; do
    [[ -z "$host" || "$host" =~ ^# ]] && continue
    ALLOW_ACL+="acl lab_dst dstdomain ${host}"$'\n'
  done <"$ALLOW_FILE"
fi

case "$MODE" in
  negotiate|kerberos)
    if [[ ! -x "$NEGOTIATE_HELPER" ]]; then
      echo "ERROR: negotiate helper missing: ${NEGOTIATE_HELPER}" >&2
      exit 1
    fi
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
    if [[ ! -f "$KRB5_KTNAME" ]]; then
      echo "ERROR: corporate keytab missing at ${KRB5_KTNAME}" >&2
      exit 1
    fi
    TEMPLATE=/etc/squid/squid.conf.negotiate.template
    sed \
      -e "s|__NEGOTIATE_HELPER__|${NEGOTIATE_HELPER}|g" \
      -e "s|__HTTP_SPN__|HTTP/${CORP_HOST}@${REALM}|g" \
      "$TEMPLATE" >/tmp/squid.conf
    ;;
  ntlm)
    if [[ ! -x "$NTLM_HELPER" ]]; then
      # Some images ship the helper without +x or under a slightly different name.
      if [[ -f "$NTLM_HELPER" ]]; then
        chmod 0755 "$NTLM_HELPER" || true
      fi
    fi
    if [[ ! -x "$NTLM_HELPER" ]]; then
      echo "ERROR: NTLM helper missing: ${NTLM_HELPER}" >&2
      ls -la /usr/lib/squid/ >&2 || true
      exit 1
    fi
    TEMPLATE=/etc/squid/squid.conf.ntlm.template
    sed -e "s|__NTLM_HELPER__|${NTLM_HELPER}|g" "$TEMPLATE" >/tmp/squid.conf
    echo "corporate-proxy AUTH_MODE=ntlm helper=${NTLM_HELPER}"
    ;;
  *)
    echo "ERROR: PROXY_AUTH_MODE must be negotiate|kerberos|ntlm (got ${MODE})" >&2
    exit 1
    ;;
esac

awk -v acl="$ALLOW_ACL" '
  /__ALLOW_ACL__/ { printf "%s", acl; next }
  { print }
' /tmp/squid.conf >/tmp/squid.conf.final

rm -f /var/run/squid/squid.pid
exec squid -N -f /tmp/squid.conf.final
