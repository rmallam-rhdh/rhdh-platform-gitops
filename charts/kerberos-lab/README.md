# Kerberos lab (Negotiate proxy for RHDH)

**Lab only.** Self-contained MIT Kerberos realm + Negotiate “corporate” Squid + no-auth bridge that speaks Negotiate upstream. Used to prove the Hub pattern when the customer proxy is Kerberos-only (no Basic).

```text
RHDH (namespace rhdh-kerberos)
  HTTP_PROXY=http://bridge.kerberos-lab.svc:3128   # no auth
        │
        ▼
bridge (Squid, login=NEGOTIATE to parent)
        │
        ▼
corporate-proxy (Squid, requires Negotiate)  ← simulates customer
        │
        ▼
allow-listed HTTPS destinations

kdc (MIT krb5) issues keytabs on a shared PVC
```

This is **not** Red Hat–supported RHDH Kerberos auth. It is a platform spike.

## 1. Build and push images

Requires a logged-in `oc` session and a running `podman machine`.

```bash
cd charts/kerberos-lab
# Create namespace + allow push to internal registry (example)
oc create ns kerberos-lab --dry-run=client -o yaml | oc apply -f -
oc -n kerberos-lab policy add-role-to-user system:image-builder -z default

# Local build (tags kerberos-lab-*:0.1.0)
./scripts/build-images.sh

# Push after oc registry login
HOST="$(oc get route default-route -n openshift-image-registry -o jsonpath='{.spec.host}' 2>/dev/null || true)"
if [[ -n "$HOST" ]]; then
  podman login -u "$(oc whoami)" -p "$(oc whoami -t)" "$HOST"
  REGISTRY="${HOST}/kerberos-lab" ./scripts/build-images.sh
fi
```

Edit `values-deploy.yaml` if your registry path differs. Argo apps sync from `main` — push this chart (or `helm upgrade` from the local tree) before expecting the cluster to pull new images.

## 2. Deploy the lab stack

```bash
oc apply -f argocd/apps/kerberos-lab.yaml
# or: helm upgrade -i kerberos-lab charts/kerberos-lab \
#       -n kerberos-lab --create-namespace \
#       -f charts/kerberos-lab/values.yaml \
#       -f charts/kerberos-lab/values-deploy.yaml
```

Wait until `kdc`, `corporate-proxy`, and `bridge` are Ready.

## 3. Deploy the dedicated Hub (`rhdh-kerberos`)

Separate from the main `rhdh` instance:

```bash
# Create secrets first (guest-friendly lab)
oc apply -f examples/rhdh-kerberos-secrets.example.yaml

oc apply -f argocd/apps/developer-hub-kerberos.yaml
```

Hub URL (typical):

`https://backstage-developer-hub-kerberos-rhdh-kerberos.<clusterBaseDomain>`

Set `app.clusterBaseDomain` in `charts/developer-hub/values-kerberos-lab.yaml` before sync.

## 4. Smoke test

```bash
./charts/kerberos-lab/scripts/smoke-test.sh
```

Or from the Hub pod:

```bash
oc -n rhdh-kerberos exec deploy/backstage-backend -c backstage-backend -- \
  sh -c 'echo "$HTTPS_PROXY"; node --use-env-proxy -e "fetch(\"https://example.com\").then(r=>console.log(r.status))"'
```

## Tests

```bash
./charts/kerberos-lab/tests/test-chart.sh
```

## Cleanup

```bash
oc delete -f argocd/apps/developer-hub-kerberos.yaml
oc delete -f argocd/apps/kerberos-lab.yaml
oc delete ns rhdh-kerberos kerberos-lab
```
