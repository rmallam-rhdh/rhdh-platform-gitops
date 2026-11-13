#!/usr/bin/env bash
set -euo pipefail

# PROXY_AUTH_MODE=kerberos|negotiate (default) | ntlm
MODE="$(echo "${PROXY_AUTH_MODE:-kerberos}" | tr '[:upper:]' '[:lower:]')"
REALM="${REALM:-LAB.LOCAL}"
KDC_HOST="${KDC_HOSTNAME:-kdc.kerberos-lab.svc.cluster.local}"
CORP="${CORPORATE_PROXY_HOSTNAME:-corporate-proxy.kerberos-lab.svc.cluster.local}"
CORP_PORT="${CORPORATE_PROXY_PORT:-3128}"
CLIENT_PRINC="${BRIDGE_CLIENT_PRINCIPAL:-rhdh-bridge@${REALM}}"
KTNAME="${KRB5_KTNAME:-/keytabs/bridge-client.keytab}"
RENEW_INTERVAL_SECONDS="${RENEW_INTERVAL_SECONDS:-14400}"
LISTEN_PORT="${BRIDGE_LISTEN_PORT:-3128}"
LISTEN_ADDR="${BRIDGE_LISTEN_ADDR:-127.0.0.1}"

mkdir -p /tmp/squid

run_kerberos() {
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
  export KRB5CCNAME="FILE:/tmp/krb5cc_bridge"

  if [[ ! -f "$KTNAME" ]]; then
    echo "ERROR: keytab missing at ${KTNAME}" >&2
    exit 1
  fi

  kinit_once() {
    kinit -kt "$KTNAME" "$CLIENT_PRINC" 2>/tmp/kinit.err
  }

  for i in $(seq 1 60); do
    if kinit_once; then
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
      sleep "$RENEW_INTERVAL_SECONDS"
      if ! kinit_once; then
        echo "WARN: ticket renew failed: $(cat /tmp/kinit.err 2>/dev/null || true)" >&2
      fi
    done
  ) &

  sed \
    -e "s|__CORP_HOST__|${CORP}|g" \
    -e "s|__CORP_PORT__|${CORP_PORT}|g" \
    /etc/squid/squid.conf.template >/tmp/squid.conf

  rm -f /tmp/squid/squid.pid
  echo "bridge AUTH_MODE=kerberos peer=${CORP}:${CORP_PORT}"
  exec /usr/sbin/squid -N -f /tmp/squid.conf
}

run_ntlm() {
  local user="${NTLM_USERNAME:-}"
  local pass="${NTLM_PASSWORD:-}"
  local domain="${NTLM_DOMAIN:-LAB}"

  if [[ -z "$user" || -z "$pass" ]]; then
    echo "ERROR: NTLM_USERNAME and NTLM_PASSWORD are required for PROXY_AUTH_MODE=ntlm" >&2
    exit 1
  fi
  if ! command -v cntlm >/dev/null 2>&1; then
    echo "ERROR: cntlm binary missing in image" >&2
    exit 1
  fi

  # Escape sed replacements carefully (passwords may contain & / \).
  local esc_user esc_pass esc_domain esc_host esc_port esc_listen esc_addr
  esc_user=$(printf '%s' "$user" | sed -e 's/[&/\]/\\&/g')
  esc_pass=$(printf '%s' "$pass" | sed -e 's/[&/\]/\\&/g')
  esc_domain=$(printf '%s' "$domain" | sed -e 's/[&/\]/\\&/g')
  esc_host=$(printf '%s' "$CORP" | sed -e 's/[&/\]/\\&/g')
  esc_port=$(printf '%s' "$CORP_PORT" | sed -e 's/[&/\]/\\&/g')
  esc_listen=$(printf '%s' "$LISTEN_PORT" | sed -e 's/[&/\]/\\&/g')
  esc_addr=$(printf '%s' "$LISTEN_ADDR" | sed -e 's/[&/\]/\\&/g')

  sed \
    -e "s|__NTLM_USER__|${esc_user}|g" \
    -e "s|__NTLM_PASS__|${esc_pass}|g" \
    -e "s|__NTLM_DOMAIN__|${esc_domain}|g" \
    -e "s|__CORP_HOST__|${esc_host}|g" \
    -e "s|__CORP_PORT__|${esc_port}|g" \
    -e "s|__LISTEN_PORT__|${esc_listen}|g" \
    -e "s|__LISTEN_ADDR__|${esc_addr}|g" \
    /etc/cntlm/cntlm.conf.template >/tmp/cntlm.conf
  chmod 0600 /tmp/cntlm.conf

  echo "bridge AUTH_MODE=ntlm peer=${CORP}:${CORP_PORT} user=${user} domain=${domain} listen=${LISTEN_ADDR}:${LISTEN_PORT}"
  # -f foreground; -c config
  exec cntlm -f -c /tmp/cntlm.conf
}

case "$MODE" in
  kerberos|negotiate) run_kerberos ;;
  ntlm) run_ntlm ;;
  *)
    echo "ERROR: PROXY_AUTH_MODE must be kerberos|negotiate|ntlm (got ${MODE})" >&2
    exit 1
    ;;
esac
