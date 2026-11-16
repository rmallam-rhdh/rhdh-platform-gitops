# Enterprise Venafi / cert-manager Leaf-Cert TLS Lab (`venafi-pki-lab`)

Proves the enterprise TLS architecture for **CloudNativePG (`backstage-psql`)** and **Red Hat Developer Hub (`developer-hub-tls`)** where:

1. **No Subordinate CA private key is ever placed in the application namespace (`rhdh-cnpg-tls-test`).**
2. Root CA (`simulated-venafi-root-ca`) and Intermediate Issuing CA (`simulated-venafi-issuing-ca`) remain strictly inside `cert-manager` behind `ClusterIssuer/simulated-venafi-issuer`.
3. `rhdh-cnpg-tls-test` receives **only**:
   - Leaf server certificate (`cnpg-server-tls`, `CA:FALSE`, `usages: [server auth]`, labeled `cnpg.io/reload: "true"`)
   - Leaf replication client certificate (`cnpg-replication-tls`, `CA:FALSE`, `usages: [client auth]`, labeled `cnpg.io/reload: "true"`)
   - Public 2-certificate CA chain (`enterprise-ca-chain` containing **only `ca.crt`**: Intermediate + Root, zero private keys)
4. **Red Hat Developer Hub (`developer-hub-tls`)** mounts **only** `enterprise-ca-chain` (`ca.crt`) via `NODE_EXTRA_CA_CERTS=/etc/pki/ca-trust/ca.crt` and connects to `backstage-psql-rw` using SCRAM-SHA-256 password auth (`backstage-psql-app`) with strict TLS (`ssl.rejectUnauthorized: true`, no `ssl.ca` in `app-config.yaml`, and no `NODE_TLS_REJECT_UNAUTHORIZED=0`).
5. **No `Secret` manifests or private keys are stored in Git.**

## Deploy via Argo CD

```bash
# 1. Pre-create the runtime RHDH session secret in rhdh-cnpg-tls-test (never stored in Git):
oc create ns rhdh-cnpg-tls-test --dry-run=client -o yaml | oc label --local -f - istio.io/dataplane-mode=none -o yaml | oc apply -f -
oc create secret generic rhdh-cnpg-tls-secrets -n rhdh-cnpg-tls-test \
  --from-literal=BACKEND_SECRET="$(openssl rand -base64 32)" \
  --from-literal=SNOW_ACCESS_TOKEN="$(openssl rand -hex 16)"

# 2. Sync the 3 Argo CD Applications:
oc apply -f argocd/apps-lab/venafi-pki-lab.yaml
oc apply -f argocd/apps-lab/cnpg-venafi-tls.yaml
oc apply -f argocd/apps-lab/developer-hub-cnpg-tls.yaml
```

For real production Venafi TPP / CyberArk deployments, skip `venafi-pki-lab.yaml` and point `tls.certManager.issuerRef.name` in `charts/cnpg/values.yaml` (or your cluster overlay) at your real Venafi `ClusterIssuer`.
