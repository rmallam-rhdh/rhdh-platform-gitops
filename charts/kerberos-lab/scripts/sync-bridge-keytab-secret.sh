#!/usr/bin/env bash
# Copy bridge-client.keytab from the lab KDC PVC into a Secret for the Hub sidecar.
# Also tags the UBI bridge image into the Hub namespace for easy pulls.
set -euo pipefail
NS_LAB="${NS_LAB:-kerberos-lab}"
NS_HUB="${NS_HUB:-rhdh-kerberos}"
SECRET="${SECRET:-kerberos-bridge-keytab}"
IMAGE_TAG="${IMAGE_TAG:-0.1.0}"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

echo "==> reading keytab from ${NS_LAB}/deploy/kdc"
oc -n "$NS_LAB" exec deploy/kdc -- cat /keytabs/bridge-client.keytab >"$TMP"
[[ -s "$TMP" ]] || { echo "empty keytab" >&2; exit 1; }

echo "==> upsert Secret ${NS_HUB}/${SECRET}"
oc -n "$NS_HUB" create secret generic "$SECRET" \
  --from-file=bridge-client.keytab="$TMP" \
  --dry-run=client -o yaml | oc apply -f -

echo "==> allow ${NS_HUB} SAs to pull from ${NS_LAB}"
oc policy add-role-to-group system:image-puller "system:serviceaccounts:${NS_HUB}" -n "$NS_LAB" 2>/dev/null || true

echo "==> tag bridge-ubi into ${NS_HUB}"
oc -n "$NS_HUB" tag "${NS_LAB}/kerberos-lab-bridge-ubi:${IMAGE_TAG}" "kerberos-lab-bridge-ubi:${IMAGE_TAG}" || true

echo "OK"
