# Negotiate bridge on Red Hat Squid (RHEL 9 / UBI lineage).
# Lab/spike only — not a supported RHDH feature.
# Hub talks to 127.0.0.1:3128 (sidecar); this container speaks Negotiate upstream.
FROM registry.redhat.io/rhel9/squid:latest

USER root
# krb5-workstation provides kinit; squid image already ships negotiate helpers.
RUN dnf -y install krb5-workstation hostname \
 && dnf clean all \
 && mkdir -p /var/spool/squid /var/log/squid /var/run/squid /tmp/squid \
 && chown -R 1001:0 /var/spool/squid /var/log/squid /var/run/squid /tmp/squid \
 && chmod -R g+rwX /var/spool/squid /var/log/squid /var/run/squid /tmp/squid

COPY entrypoint.sh /entrypoint.sh
COPY squid.conf.template /etc/squid/squid.conf.template
RUN chmod 0755 /entrypoint.sh \
 && chown 1001:0 /entrypoint.sh /etc/squid/squid.conf.template

ENV REALM=LAB.LOCAL \
    KRB5_KTNAME=/keytabs/bridge-client.keytab \
    HOME=/tmp

USER 1001
EXPOSE 3128
ENTRYPOINT ["/entrypoint.sh"]
