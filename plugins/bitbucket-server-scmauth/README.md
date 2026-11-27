# `@internal/plugin-bitbucket-server-scmauth`

Standard Backstage `1.49.2` / Red Hat Developer Hub (RHDH `1.10`) TypeScript dynamic frontend plugin that overrides `scmAuthApiRef` (`core.scmauth`) using official `@backstage/integration-react` (`ScmAuth.forBitbucketServer`, `ScmAuth.forGithub`, `ScmAuth.forGitlab`, `ScmAuth.forAzure`, `ScmAuth.forBitbucket`, `ScmAuth.merge`).

## Why This Plugin Exists

RHDH 1.10 ships `bitbucketServerAuthApiRef` (`core.auth.bitbucket-server`) and the backend `/api/auth/bitbucketServer/*` provider out of the box, but its compiled static `packages/app/src/apis.ts` omits `bitbucketServer` from `scmAuthApiRef`. Registering `scmAuthApi` from this dynamic frontend plugin enables per-user Bitbucket Data Center OAuth 2.0 consent popups in Scaffolder `RepoUrlPicker` (`requestUserCredentials`) without rebuilding the RHDH container image.

## Integrating into an Existing RHDH Dynamic Plugins Repo (Alongside Snyk / DX)

Copy this `bitbucket-server-scmauth/` folder directly into `plugins/bitbucket-server-scmauth/` of your existing Backstage `1.49.x` / RHDH `1.10` dynamic plugin build repository, then run your standard pipeline:

```bash
yarn install
yarn tsc
yarn --cwd plugins/bitbucket-server-scmauth test --watchAll=false
yarn --cwd plugins/bitbucket-server-scmauth build
cd plugins/bitbucket-server-scmauth
npx @red-hat-developer-hub/cli@1.10.8 plugin export

# Package Option A — OCI Image (same workflow as Snyk / DX):
npx @red-hat-developer-hub/cli@1.10.8 plugin package \
  --tag quay.apps.example.com/rhdh/plugin-bitbucket-server-scmauth:0.1.0
podman push quay.apps.example.com/rhdh/plugin-bitbucket-server-scmauth:0.1.0

# Package Option B — NPM Tarball (.tgz + sha512 integrity):
npm pack ./dist-dynamic --pack-destination ../../dist
openssl dgst -sha512 -binary ../../dist/internal-plugin-bitbucket-server-scmauth-dynamic-0.1.0.tgz | openssl base64 -A
```

## Optional Runtime Scope Override (`app-config.yaml`)

By default, Bitbucket Data Center requests `['PUBLIC_REPOS', 'REPO_READ']` for reads and adds `['REPO_WRITE', 'PROJECT_ADMIN']` when `repoWrite: true` is set. You can override these scopes in `app-config.yaml` without modifying or rebuilding the plugin:

```yaml
auth:
  bitbucketServer:
    scopeMapping:
      default:
        - PUBLIC_REPOS
        - REPO_READ
      repoWrite:
        - REPO_WRITE
```
