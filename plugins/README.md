# Custom RHDH 1.10 Dynamic Plugins (`plugins/`)

This directory contains the TypeScript source workspace, pre-exported assets, and `.tgz` distribution tarballs for custom Red Hat Developer Hub (`1.10` / Backstage `1.49.2`) dynamic plugins used by this platform:

| Plugin | Source Location | Exported Artifact (`plugins/dist/`) | Purpose |
| :--- | :--- | :--- | :--- |
| **`@internal/plugin-bitbucket-server-scmauth`** | [`plugins/bitbucket-server-scmauth/`](./bitbucket-server-scmauth/) *(Full TypeScript `src/`, `config.d.ts`, Jest unit tests)* | `internal-plugin-bitbucket-server-scmauth-dynamic-0.1.0.tgz` | Registers `integrations.bitbucketServer` Data Center hosts in `scmAuthApiRef` (`ScmAuth.forBitbucketServer`) alongside GitHub/GitLab/Azure/Bitbucket Cloud so Scaffolder `RepoUrlPicker` triggers per-user Bitbucket DC OAuth 2.0 popups. See [`docs/rhdh-bitbucket-datacenter-oauth-golden-path.md`](../docs/rhdh-bitbucket-datacenter-oauth-golden-path.md). |
| **Enterprise Vault Namespace Fork (`@backstage-community/plugin-vault@0.19.0`)** | Standalone fork guide: [`docs/vault-plugin-bitbucket-fork-guide.md`](../docs/vault-plugin-bitbucket-fork-guide.md) *(Lab reference bundles in `vault-namespace*`)* | `internal-plugin-vault-namespace-dynamic-0.1.0.tgz`, `internal-plugin-vault-namespace-backend-dynamic-0.1.0.tgz` | Adds HashiCorp Vault Enterprise `X-Vault-Namespace` multi-tenancy, Pod ServiceAccount Kubernetes Auth JWT caching, and RHDH `PermissionsService` + `vault.io/allowed-principals` RBAC enforcement. |

---

## Building & Exporting `bitbucket-server-scmauth` from Source

You can either drop `plugins/bitbucket-server-scmauth/` straight into `plugins/` of an existing RHDH dynamic-plugin packaging repository (alongside Snyk, DX, etc.) **or** build it directly inside this `plugins/` Yarn 4 workspace:

```bash
cd plugins
corepack enable
yarn plugin import https://versions.backstage.io/v1/releases/1.49.2/yarn-plugin
yarn install

# 1. Type-check, unit-test, and build TypeScript source
yarn tsc
yarn test
yarn build:all

# 2. Export RHDH 1.10 dynamic frontend plugin (generates dist-dynamic/ + dist-scalprum/)
yarn export:scmauth

# 3A. Package as OCI image (recommended alongside Snyk / DX):
cd bitbucket-server-scmauth
npx @red-hat-developer-hub/cli@1.10.8 plugin package \
  --tag quay.apps.example.com/rhdh/plugin-bitbucket-server-scmauth:0.1.0

# 3B. Or pack as .tgz tarball into plugins/dist/ and print sha512 integrity:
npm pack ./dist-dynamic --pack-destination ../dist
echo "sha512-$(openssl dgst -sha512 -binary ../dist/internal-plugin-bitbucket-server-scmauth-dynamic-0.1.0.tgz | openssl base64 -A)"
```
