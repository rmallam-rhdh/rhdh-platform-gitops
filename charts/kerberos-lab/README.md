# Kerberos / NTLM lab (corporate proxy for RHDH)

**Lab only.** Dual-mode parent: MIT Kerberos + Negotiate Squid **or** Squid `ntlm_fake_auth`. Bridge is UBI Negotiate (Kerberos) or Ubuntu **cntlm** (NTLM). Used to prove Hub outbound HTTPS when the customer proxy has no Basic.

NTLM overlay: `values-ntlm-lab.yaml` + Hub `values-kerberos-ntlm-lab.yaml`. Local smoke: `scripts/smoke-ntlm-podman.sh`. Cluster smoke (no Hub): `scripts/smoke-ntlm-cluster.sh`. Design notes: `idp-platform-docs/proxy/kerberos-ntlm-dual-mode.md`.

| Doc | Purpose |
|---|---|
| **[SIDECAR.md](SIDECAR.md)** | Negotiate (Kerberos) sidecar — spec, env, keytab/SPN, failure modes |
| **[SIDECAR-NTLM.md](SIDECAR-NTLM.md)** | NTLM sidecar — cntlm handshake, Secret, failure modes |
| [PROXY-AUTH.md](../developer-hub/PROXY-AUTH.md) | Supported **Basic** proxy answers |
| `.share/SIDECAR-NTLM-customer.md` → `SIDECAR-NTLM-customer.pdf` | Customer-share NTLM PDF (same style as Negotiate) |

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

kdc (MIT krb5) issues keytabs → PostSync Job / sync script → Secret kerberos-bridge-keytab
```

This is **not** Red Hat–supported RHDH Kerberos auth. It is a platform spike. Prefer customer **Basic** on the corporate proxy when available.

Image: `ghcr.io/rmallam-rhdh/kerberos-lab-bridge-ubi:0.1.0` (also built into the cluster registry).

Argo Applications are **opt-in** under [`argocd/apps-lab/`](../../argocd/apps-lab/) (not default app-of-apps).

## 1. Build and push images

```bash
cd charts/kerberos-lab
oc create ns kerberos-lab --dry-run=client -o yaml | oc apply -f -
oc -n kerberos-lab policy add-role-to-user system:image-builder -z default
./scripts/build-images.sh
HOST="$(oc get route default-route -n openshift-image-registry -o jsonpath='{.spec.host}' 2>/dev/null || true)"
if [[ -n "$HOST" ]]; then
  podman login -u "$(oc whoami)" -p "$(oc whoami -t)" "$HOST"
  REGISTRY="${HOST}/kerberos-lab" ./scripts/build-images.sh
fi
```

`bridge-ubi` pulls `registry.redhat.io/rhel9/squid`. Edit `values-deploy.yaml` if your registry path differs.

## 2. Deploy the lab stack (KDC + corporate proxy + keytab sync)

```bash
helm upgrade -i kerberos-lab charts/kerberos-lab \
  -n kerberos-lab --create-namespace \
  -f charts/kerberos-lab/values.yaml \
  -f charts/kerberos-lab/values-deploy.yaml \
  --set createNamespace=false
# or: oc apply -f argocd/apps-lab/kerberos-lab.yaml
```

Wait until `kdc` and `corporate-proxy` are Ready. The PostSync Job `keytab-sync` copies the client keytab into `rhdh-kerberos/kerberos-bridge-keytab` (creates Hub namespace if needed). Manual alternative: `./scripts/sync-bridge-keytab-secret.sh`.

## 3. Hub Secret (localhost proxy)

```bash
oc apply -f examples/rhdh-kerberos-secrets.example.yaml
# Ensure HTTP_PROXY / HTTPS_PROXY are http://127.0.0.1:3128 (no userinfo).
```

## 4. Deploy the dedicated Hub (`rhdh-kerberos`)

```bash
helm upgrade -i developer-hub-kerberos charts/developer-hub \
  -n rhdh-kerberos \
  -f charts/developer-hub/values.yaml \
  -f charts/developer-hub/values-kerberos-lab.yaml \
  --set createNamespace=false
# or: oc apply -f argocd/apps-lab/developer-hub-kerberos.yaml
```

## 5. Preflight + smoke

```bash
./charts/kerberos-lab/scripts/preflight-sidecar.sh
./charts/kerberos-lab/scripts/smoke-test.sh
```

Or:

```bash
oc -n rhdh-kerberos exec deploy/backstage-developer-hub-kerberos -c backstage-backend -- \
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
oc delete -f argocd/apps-lab/ --ignore-not-found || true
oc delete ns rhdh-kerberos kerberos-lab
```
