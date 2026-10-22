# Kerberos lab (Negotiate proxy for RHDH)

**Lab only.** Self-contained MIT Kerberos realm + Negotiate “corporate” Squid + UBI/RHEL 9 Negotiate bridge (Hub sidecar). Used to prove the Hub pattern when the customer proxy is Kerberos-only (no Basic).

**Architecture and sidecar spec** (ports, env, keytab, what the corporate proxy must provide): see **[SIDECAR.md](SIDECAR.md)**.

```text
RHDH pod (namespace rhdh-kerberos)
  backstage-backend
    HTTP_PROXY=http://127.0.0.1:3128   # no auth
        │
        ▼  (localhost)
  kerberos-bridge sidecar (rhel9/squid + krb5, login=NEGOTIATE)
        │
        ▼
corporate-proxy (Squid, requires Negotiate)  ← simulates customer
        │
        ▼
allow-listed HTTPS destinations

kdc (MIT krb5) issues keytabs; sync into Secret kerberos-bridge-keytab
```

This is **not** Red Hat–supported RHDH Kerberos auth. It is a platform spike.

Image: `ghcr.io/rmallam-rhdh/kerberos-lab-bridge-ubi:0.1.0` (also built into the cluster registry).

Standalone bridge Deployment (`bridge.enabled`) remains available for debugging; the cluster overlay (`values-deploy.yaml`) turns it off when the Hub sidecar is used.

## 1. Build and push images

Requires a logged-in `oc` session and a running `podman machine` (or OpenShift binary build — see below).

```bash
cd charts/kerberos-lab
oc create ns kerberos-lab --dry-run=client -o yaml | oc apply -f -
oc -n kerberos-lab policy add-role-to-user system:image-builder -z default

# Local build (tags kerberos-lab-*:0.1.0 including bridge-ubi)
./scripts/build-images.sh

# Push after oc registry login
HOST="$(oc get route default-route -n openshift-image-registry -o jsonpath='{.spec.host}' 2>/dev/null || true)"
if [[ -n "$HOST" ]]; then
  podman login -u "$(oc whoami)" -p "$(oc whoami -t)" "$HOST"
  REGISTRY="${HOST}/kerberos-lab" ./scripts/build-images.sh
fi
```

`bridge-ubi` pulls `registry.redhat.io/rhel9/squid` — ensure the build host / cluster pull secret can reach that registry.

Edit `values-deploy.yaml` if your registry path differs.

## 2. Deploy the lab stack (KDC + corporate proxy)

```bash
helm upgrade -i kerberos-lab charts/kerberos-lab \
  -n kerberos-lab --create-namespace \
  -f charts/kerberos-lab/values.yaml \
  -f charts/kerberos-lab/values-deploy.yaml
```

Wait until `kdc` and `corporate-proxy` are Ready.

## 3. Sync keytab Secret into the Hub namespace

```bash
./charts/kerberos-lab/scripts/sync-bridge-keytab-secret.sh
```

## 4. Deploy / upgrade the dedicated Hub (`rhdh-kerberos`)

```bash
# Secret: HTTP_PROXY=http://127.0.0.1:3128 (see examples/rhdh-kerberos-secrets.example.yaml)
oc apply -f examples/rhdh-kerberos-secrets.example.yaml   # or patch existing

helm upgrade -i developer-hub-kerberos charts/developer-hub \
  -n rhdh-kerberos \
  -f charts/developer-hub/values.yaml \
  -f charts/developer-hub/values-kerberos-lab.yaml
```

Hub URL (typical):

`https://backstage-developer-hub-kerberos-rhdh-kerberos.<clusterBaseDomain>`

## 5. Smoke test

```bash
./charts/kerberos-lab/scripts/smoke-test.sh
```

Or from the Hub pod (via sidecar localhost):

```bash
oc -n rhdh-kerberos exec deploy/backstage-backend -c backstage-backend -- \
  sh -c 'echo "$HTTPS_PROXY"; node --use-env-proxy -e "fetch(\"https://example.com\").then(r=>console.log(r.status))"'
```

## Tests

```bash
./charts/kerberos-lab/tests/test-chart.sh
./charts/developer-hub/tests/test-chart.sh
```

## Cleanup

```bash
helm uninstall developer-hub-kerberos -n rhdh-kerberos || true
helm uninstall kerberos-lab -n kerberos-lab || true
oc delete ns rhdh-kerberos kerberos-lab
```
