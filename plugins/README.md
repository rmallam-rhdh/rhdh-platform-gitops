# Enterprise Vault Namespace RHDH Dynamic Plugins (`@internal/plugin-vault-namespace*`)

Custom Red Hat Developer Hub (RHDH 1.10 / Backstage 1.49.4) dynamic plugins that close the enterprise security gaps in upstream `@backstage-community/plugin-vault` for **HashiCorp Vault Enterprise with Vault Namespaces**:

| Capability | Upstream `@backstage-community/plugin-vault` | `@internal/plugin-vault-namespace*` (This Directory) |
| :--- | :--- | :--- |
| **Vault Enterprise Namespaces** | Missing (`v1/<mount>` hardcoded, `encodeURIComponent` breaks `/`) | Sends `X-Vault-Namespace: <vault.io/namespace>` + `?namespace=` UI deep-links |
| **RHDH RBAC Enforcement** | None (any user can enumerate arbitrary paths via URL) | Zero client-supplied paths; enforces `PermissionsService` (`catalog.entity.read`) + `vault.io/allowed-principals` team guard **before** calling Vault |
| **Authentication to Vault** | Static token or Kube Auth on single namespace | Pod ServiceAccount **Kubernetes Auth JWT** (`metadata/*` `list`/`read` ONLY — zero `data/*` secret value access) |
| **RHDH 1.10 Frontend Bundle** | Missing `dist-scalprum/` in `pr_1225__0.19.0` | Self-contained 3.7 KB Scalprum bundle (`EntityVaultNamespaceCard` + `isVaultNamespaceAvailable`) |

## Required `catalog-info.yaml` Annotations

```yaml
metadata:
  annotations:
    vault.io/namespace: payments/nonprod
    vault.io/secrets-path: ledger-service
    # Optional custom KV v2 mount inside that Vault namespace (defaults to vaultNamespace.defaultMount = "kv")
    vault.io/secrets-engine: kv
    # Optional team/group RBAC guard enforced by RHDH backend before querying Vault
    vault.io/allowed-principals: group:default/developers,group:default/payments-team
```

## Rebuilding Distribution Tarballs (`plugins/dist/*.tgz`)

```bash
npm pack ./plugins/vault-namespace-backend --pack-destination ./plugins/dist
npm pack ./plugins/vault-namespace --pack-destination ./plugins/dist
for f in plugins/dist/*.tgz; do
  echo "$f: sha512-$(openssl dgst -sha512 -binary "$f" | openssl base64 -A)"
done
```
