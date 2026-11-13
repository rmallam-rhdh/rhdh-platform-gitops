#!/usr/bin/env bash
set -euo pipefail

REALM="${REALM:-LAB.LOCAL}"
DOMAIN_REALM="$(echo "$REALM" | tr '[:upper:]' '[:lower:]')"
MASTER_PW="${MASTER_PASSWORD:-lab-master-password-change-me}"
ADMIN_PW="${ADMIN_PASSWORD:-lab-admin-password-change-me}"
CORP_HOST="${CORPORATE_PROXY_HOSTNAME:-corporate-proxy.kerberos-lab.svc.cluster.local}"
BRIDGE_HOST="${BRIDGE_HOSTNAME:-bridge.kerberos-lab.svc.cluster.local}"
KEYTAB_DIR="${KEYTAB_DIR:-/keytabs}"

cat >/etc/krb5.conf <<EOF
[libdefaults]
  default_realm = ${REALM}
  dns_lookup_realm = false
  dns_lookup_kdc = false
  rdns = false
  forwardable = true
  ticket_lifetime = 24h
  renew_lifetime = 7d

[realms]
  ${REALM} = {
    kdc = localhost
    admin_server = localhost
  }

[domain_realm]
  .${DOMAIN_REALM} = ${REALM}
  ${DOMAIN_REALM} = ${REALM}
EOF

# Persist KDC DB on the shared PVC (single RWO mount at KEYTAB_DIR).
KDC_DATA="${KEYTAB_DIR}/kdc-data"
mkdir -p "$KDC_DATA" /etc/krb5kdc "$KEYTAB_DIR"
# Alpine tools default under /var/lib/krb5kdc — point that at the PVC.
rm -rf /var/lib/krb5kdc
ln -sfn "$KDC_DATA" /var/lib/krb5kdc

# Alpine kadmind defaults to /var/lib/krb5kdc/kadm5.acl
cat >"${KDC_DATA}/kadm5.acl" <<EOF
*/admin@${REALM} *
EOF
cp "${KDC_DATA}/kadm5.acl" /etc/krb5kdc/kadm5.acl

cat >"${KDC_DATA}/kdc.conf" <<EOF
[kdcdefaults]
  kdc_ports = 88
  kdc_tcp_ports = 88

[realms]
  ${REALM} = {
    database_name = ${KDC_DATA}/principal
    acl_file = ${KDC_DATA}/kadm5.acl
    key_stash_file = ${KDC_DATA}/.k5.${REALM}
    max_life = 10h 0m 0s
    max_renewable_life = 7d 0h 0m 0s
  }
EOF
export KRB5_KDC_PROFILE="${KDC_DATA}/kdc.conf"

if [[ ! -f "${KDC_DATA}/principal" ]]; then
  echo "Initializing realm ${REALM}"
  kdb5_util create -s -r "$REALM" -P "$MASTER_PW"
  kadmin.local -q "addprinc -pw ${ADMIN_PW} admin/admin@${REALM}"
  kadmin.local -q "addprinc -randkey HTTP/${CORP_HOST}@${REALM}"
  kadmin.local -q "addprinc -randkey HTTP/${BRIDGE_HOST}@${REALM}"
  kadmin.local -q "ktadd -k ${KEYTAB_DIR}/corporate.keytab HTTP/${CORP_HOST}@${REALM}"
  kadmin.local -q "ktadd -k ${KEYTAB_DIR}/bridge.keytab HTTP/${BRIDGE_HOST}@${REALM}"
  # Client principal used by the bridge when acting as Negotiate client to corporate proxy
  kadmin.local -q "addprinc -randkey rhdh-bridge@${REALM}"
  kadmin.local -q "ktadd -k ${KEYTAB_DIR}/bridge-client.keytab rhdh-bridge@${REALM}"
  chmod 0444 "${KEYTAB_DIR}"/*.keytab
  echo "Keytabs written under ${KEYTAB_DIR}"
fi

krb5kdc
# kadmind is optional for this lab (keytabs already minted via kadmin.local)
kadmind || echo "WARN: kadmind failed to start (lab continues with krb5kdc only)" >&2
echo "KDC ready for realm ${REALM}"
# Keep PID 1 alive while krb5kdc runs in background
exec sleep infinity
