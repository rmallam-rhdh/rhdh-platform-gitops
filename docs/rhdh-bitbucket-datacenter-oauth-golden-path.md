# RHDH 1.10: Bitbucket Data Center (Server) OAuth 2.0, `scmAuthApi` Plugin Build & Golden Path Scaffolder Guide

## 1. Overview & Architecture

In Red Hat Developer Hub (RHDH 1.10), when developers sign in using an enterprise SSO provider (such as Microsoft Entra ID / OIDC) and run a Golden Path Software Template to scaffold a new repository or open a Pull Request in **Bitbucket Data Center (Bitbucket Server)**, two authentication mechanisms work together:

<table>
  <thead>
    <tr>
      <th>Authentication Layer</th>
      <th>RHDH Configuration Block</th>
      <th>Purpose &amp; Audit Trail</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td><strong>1. Per-User OAuth 2.0 (Interactive Template Execution)</strong></td>
      <td><code>auth.providers.bitbucketServer</code> + <code>requestUserCredentials</code> in the template's <code>RepoUrlPicker</code></td>
      <td>Prompts the logged-in developer with a Bitbucket Data Center OAuth 2.0 popup on their first run, caches an encrypted refresh cookie in their browser, and injects their personal access token into <code>${{ secrets.USER_OAUTH_TOKEN }}</code>. Repositories, commits, and Pull Requests are created under the <strong>developer's own Bitbucket identity</strong> and enforce their Bitbucket Project permissions.</td>
    </tr>
    <tr>
      <td><strong>2. Host Registration &amp; Background Service Account</strong></td>
      <td><code>integrations.bitbucketServer</code></td>
      <td>Registers the Bitbucket Data Center hostname so <code>RepoUrlPicker</code> and <code>scmAuthApi</code> recognize the host, and provides a background HTTP Access Token for asynchronous Catalog Discovery / <code>catalog-info.yaml</code> ingestion where no interactive browser session exists.</td>
    </tr>
  </tbody>
</table>

### Key Per-User OAuth Behaviors
1. **Prompted Only Once (First Run)**:
   - The first time a developer opens a Golden Path template using `RepoUrlPicker` with `requestUserCredentials`, RHDH checks `/api/auth/bitbucketServer/refresh`. If the developer has no active Bitbucket session cookie, `RepoUrlPicker` opens a Bitbucket Data Center OAuth 2.0 consent popup (`Allow`).
   - RHDH stores the encrypted OAuth refresh token in an `HttpOnly` cookie scoped to `/api/auth/bitbucketServer` in that developer's browser.
   - On subsequent Golden Path runs, RHDH silently refreshes the access token in the background without prompting the developer again (until the Bitbucket refresh token expires).
2. **100% Isolated Per Developer**:
   - The OAuth session cookie lives exclusively in that developer's browser, and `secrets.USER_OAUTH_TOKEN` is passed only to that single Scaffolder task execution in memory.
   - Other RHDH users cannot see or reuse another developer's Bitbucket OAuth token.

---

## 2. Bitbucket Data Center Application Link & Required OAuth 2.0 Scopes

To enable OAuth 2.0 in Bitbucket Data Center (Bitbucket Server 7.14+ / 8.x / 9.x), a Bitbucket Administrator must create an **Incoming Application Link**:

### Step 1: Create the Incoming Application Link in Bitbucket Data Center
1. Go to **Administration (Gear Icon) → Application Links**.
2. Click **Create link**.
3. Select **External application** and direction **Incoming**, then click **Continue**.
4. Fill in the application details:
   - **Name**: `Red Hat Developer Hub`
   - **Redirect URL**:
     ```text
     https://<rhdh-route-hostname>/api/auth/bitbucketServer/handler/frame
     ```
5. Select the **Application Permissions (OAuth 2.0 Scopes)** listed in the table below and click **Save**.
6. Copy the generated **Client ID** and **Client Secret** for RHDH (`BITBUCKET_OAUTH_CLIENT_ID` and `BITBUCKET_OAUTH_CLIENT_SECRET`).

### Step 2: Required OAuth 2.0 Scopes on the Bitbucket Data Center App

When the Golden Path template creates a **new repository** (`publish:bitbucketServer`), the Bitbucket Data Center OAuth app **must** have **Project Admin (`PROJECT_ADMIN`)** and **Repository Write (`REPO_WRITE`)** (along with the default read scopes):

<table>
  <thead>
    <tr>
      <th>Bitbucket Data Center Scope Name</th>
      <th>RHDH / API Scope ID</th>
      <th>Required?</th>
      <th>Why RHDH Requires This Scope</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td><strong>Project Admin</strong></td>
      <td><code>PROJECT_ADMIN</code></td>
      <td><strong>Yes (Required to create repos)</strong></td>
      <td><code>publish:bitbucketServer</code> calls <code>POST /rest/api/1.0/projects/{projectKey}/repos</code>. In Bitbucket Data Center's REST API permission model, creating a new repository inside a Bitbucket Project requires <code>PROJECT_ADMIN</code> (Repository Write alone only allows pushing to an <em>existing</em> repo).</td>
    </tr>
    <tr>
      <td><strong>Repository Admin</strong></td>
      <td><code>REPO_ADMIN</code></td>
      <td><strong>Yes</strong> <em>(included with Project Admin)</em></td>
      <td>Required if the template enables Git LFS (<code>PUT /rest/git-lfs/admin/projects/{project}/repos/{repo}/enabled</code>), configures branch permissions, or manages webhooks.</td>
    </tr>
    <tr>
      <td><strong>Repository Write</strong></td>
      <td><code>REPO_WRITE</code></td>
      <td><strong>Yes</strong></td>
      <td>Requested by Backstage <code>ScmAuth.forBitbucketServer</code> (<code>repoWrite: true</code>) to push the initial Golden Path skeleton commit (<code>git push</code>) and to open Pull Requests (<code>publish:bitbucketServer:pull-request</code>).</td>
    </tr>
    <tr>
      <td><strong>Repository Read</strong></td>
      <td><code>REPO_READ</code></td>
      <td><strong>Yes</strong></td>
      <td>Requested by <code>ScmAuth.forBitbucketServer</code> default scopes (<code>["PUBLIC_REPOS", "REPO_READ"]</code>) so <code>BitbucketRepoPicker</code> can list available projects, repositories, and branches in the template UI.</td>
    </tr>
    <tr>
      <td><strong>Public Repositories</strong></td>
      <td><code>PUBLIC_REPOS</code></td>
      <td><strong>Yes</strong></td>
      <td>Hardcoded in Backstage's <code>ScmAuth.forBitbucketServer</code> default scope list (<code>["PUBLIC_REPOS", "REPO_READ"]</code>). If this checkbox is not enabled on the Bitbucket Application Link, Bitbucket rejects the OAuth popup with <code>invalid_scope</code>.</td>
    </tr>
  </tbody>
</table>

> **Important Note on User Permissions in Bitbucket Data Center:**
> OAuth 2.0 delegates the intersection of the **Application Link scopes** and the **logged-in user's own Bitbucket permissions**. An OAuth app with `PROJECT_ADMIN` does **not** elevate a read-only user to admin — the developer running the template must also have permission in Bitbucket Data Center to create repositories in the target Bitbucket Project (or, if developers do not have Project Admin rights in Bitbucket, repo creation can fall back to a dedicated service account token while PR creation uses the developer's OAuth token).

---

## 3. Creating & Packaging the `scmAuthApi` Dynamic Frontend Plugin in the Customer Environment

### 3.1 Why This Dynamic Frontend Plugin Is Required in RHDH 1.10
RHDH 1.10 already ships with:
- The `RepoUrlPicker` and `BitbucketRepoPicker` UI components (`@backstage/plugin-scaffolder`).
- The OAuth consent dialog (`@backstage/core-components`).
- The `bitbucketServerAuthApiRef` (`core.auth.bitbucket-server`) frontend OAuth client.
- The `@backstage/plugin-auth-backend-module-bitbucket-server-provider` backend OAuth handler (`/api/auth/bitbucketServer/*`).

However, RHDH 1.10's compiled static `packages/app/src/apis.ts` only registers `github`, `gitlab`, `azure`, and `bitbucket` (Bitbucket Cloud) in `scmAuthApiRef` (`core.scmauth`) and omits `bitbucketServer`:

```typescript
// Default packages/app/src/apis.ts in RHDH 1.10 (missing bitbucketServer):
const providers = [
  { key: 'github', ref: github, factory: ScmAuth.forGithub },
  { key: 'gitlab', ref: gitlab, factory: ScmAuth.forGitlab },
  { key: 'azure', ref: azure, factory: ScmAuth.forAzure },
  { key: 'bitbucket', ref: bitbucket, factory: ScmAuth.forBitbucket },
];
```

Without overriding `scmAuthApiRef` (`core.scmauth`), using `requestUserCredentials` in `RepoUrlPicker` for a Bitbucket Data Center host fails in the browser with:
`No auth provider available for 'https://bitbucket.example.com', see https://backstage.io/link?scm-auth`

Because RHDH 1.10's `DynamicRoot.tsx` allows any dynamic frontend plugin to register `apiFactories` that replace built-in API refs by ID (`core.scmauth`), we add Bitbucket Data Center OAuth popup support cleanly via a **standard Backstage `1.49.2` TypeScript dynamic frontend plugin** (`@internal/plugin-bitbucket-server-scmauth`) built and exported with `@red-hat-developer-hub/cli@1.10.8` — **the exact same workflow used for Snyk, DX, and custom enterprise RHDH plugins, with zero rebuild of the RHDH container image**.

---

### 3.2 Plugin Source Code & Build Workflow (Alongside Snyk / DX or Standalone)

The full, compile-tested TypeScript source lives in [`plugins/bitbucket-server-scmauth/`](../plugins/bitbucket-server-scmauth/) in this repository.

- **Recommended (Customer Already Packages Snyk & DX Plugins):** Copy the `plugins/bitbucket-server-scmauth/` folder directly into `plugins/bitbucket-server-scmauth/` of your existing Backstage `1.49.x` / RHDH `1.10` dynamic-plugin packaging repository so CI builds, tests, exports, and packages it alongside Snyk and DX in one pipeline.
- **Alternative (Standalone Repository):** Include the 4 workspace root files (`plugins/backstage.json`, `plugins/.yarnrc.yml`, `plugins/package.json`, `plugins/tsconfig.json`) if hosting it in its own Git repository.

#### File 1: `plugins/bitbucket-server-scmauth/package.json`
```json
{
  "name": "@internal/plugin-bitbucket-server-scmauth",
  "version": "0.1.0",
  "description": "RHDH 1.10 dynamic frontend plugin registering Bitbucket Data Center (bitbucketServer) alongside standard providers in ScmAuth",
  "license": "Apache-2.0",
  "sideEffects": false,
  "main": "src/index.ts",
  "types": "src/index.ts",
  "configSchema": "config.d.ts",
  "files": [
    "dist",
    "config.d.ts"
  ],
  "backstage": {
    "role": "frontend-plugin",
    "pluginId": "bitbucket-server-scmauth",
    "pluginPackages": [
      "@internal/plugin-bitbucket-server-scmauth"
    ]
  },
  "scalprum": {
    "name": "internal.plugin-bitbucket-server-scmauth",
    "exposedModules": {
      "PluginRoot": "./src/index.ts"
    }
  },
  "scripts": {
    "build": "backstage-cli package build",
    "clean": "backstage-cli package clean",
    "export-dynamic": "npx @red-hat-developer-hub/cli@1.10.8 plugin export",
    "lint": "backstage-cli package lint",
    "test": "backstage-cli package test"
  },
  "dependencies": {
    "@backstage/core-plugin-api": "backstage:^",
    "@backstage/integration-react": "backstage:^"
  },
  "devDependencies": {
    "@backstage/cli": "backstage:^",
    "@backstage/config": "backstage:^",
    "@types/react": "^18.3.0",
    "react": "^18.3.1",
    "react-dom": "^18.3.1",
    "react-router-dom": "^6.28.0"
  },
  "peerDependencies": {
    "react": "^16.13.1 || ^17.0.0 || ^18.0.0"
  }
}
```

#### File 2: `plugins/bitbucket-server-scmauth/config.d.ts`
Exposes optional runtime OAuth scope overrides (`@visibility frontend`) so scopes can even be adjusted in `app-config.yaml` later without modifying TypeScript or rebuilding the plugin:
```typescript
export interface Config {
  auth?: {
    bitbucketServer?: {
      /**
       * Optional OAuth 2.0 scope overrides for Bitbucket Data Center ScmAuth.
       *
       * @visibility frontend
       */
      scopeMapping?: {
        /**
         * Default read scopes requested by ScmAuth for Bitbucket Data Center.
         * Defaults to `['PUBLIC_REPOS', 'REPO_READ']`.
         *
         * @visibility frontend
         */
        default?: string[];

        /**
         * Additional write scopes requested when `repoWrite: true` is set
         * (for example, Scaffolder repository creation and Pull Requests).
         * Defaults to `['REPO_WRITE', 'PROJECT_ADMIN']`.
         *
         * @visibility frontend
         */
        repoWrite?: string[];
      };
    };
  };
}
```

#### File 3: `plugins/bitbucket-server-scmauth/src/plugin.ts`
Uses upstream `@backstage/integration-react` (`ScmAuth.forBitbucketServer`, `ScmAuth.forGithub`, `ScmAuth.forGitlab`, `ScmAuth.forAzure`, `ScmAuth.forBitbucket`, `ScmAuth.merge`):
```typescript
import {
  bitbucketAuthApiRef,
  bitbucketServerAuthApiRef,
  ConfigApi,
  configApiRef,
  createApiFactory,
  createPlugin,
  githubAuthApiRef,
  gitlabAuthApiRef,
  microsoftAuthApiRef,
} from '@backstage/core-plugin-api';
import { ScmAuth, scmAuthApiRef } from '@backstage/integration-react';

const DEFAULT_BITBUCKET_SERVER_READ_SCOPES = ['PUBLIC_REPOS', 'REPO_READ'];
const DEFAULT_BITBUCKET_SERVER_WRITE_SCOPES = ['REPO_WRITE', 'PROJECT_ADMIN'];

function getConfiguredHosts(
  configApi: ConfigApi,
  configPaths: string[],
  defaultHost?: string,
): string[] {
  const hosts = new Set<string>();

  for (const path of configPaths) {
    const entries = configApi.getOptionalConfigArray(path) ?? [];
    for (const entry of entries) {
      const host = entry.getOptionalString('host') ?? defaultHost;
      if (host) {
        hosts.add(host);
      }
    }
  }

  if (hosts.size === 0 && defaultHost) {
    hosts.add(defaultHost);
  }

  return Array.from(hosts);
}

export const scmAuthApi = createApiFactory({
  api: scmAuthApiRef,
  deps: {
    github: githubAuthApiRef,
    gitlab: gitlabAuthApiRef,
    azure: microsoftAuthApiRef,
    bitbucket: bitbucketAuthApiRef,
    bitbucketServer: bitbucketServerAuthApiRef,
    configApi: configApiRef,
  },
  factory: ({
    github,
    gitlab,
    azure,
    bitbucket,
    bitbucketServer,
    configApi,
  }) => {
    const bitbucketServerDefaultScopes =
      configApi.getOptionalStringArray(
        'auth.bitbucketServer.scopeMapping.default',
      ) ?? DEFAULT_BITBUCKET_SERVER_READ_SCOPES;

    const bitbucketServerRepoWriteScopes =
      configApi.getOptionalStringArray(
        'auth.bitbucketServer.scopeMapping.repoWrite',
      ) ?? DEFAULT_BITBUCKET_SERVER_WRITE_SCOPES;

    const providers: ScmAuth[] = [
      ...getConfiguredHosts(
        configApi,
        ['integrations.github'],
        'github.com',
      ).map(host => ScmAuth.forGithub(github, { host })),

      ...getConfiguredHosts(
        configApi,
        ['integrations.gitlab'],
        'gitlab.com',
      ).map(host => ScmAuth.forGitlab(gitlab, { host })),

      ...getConfiguredHosts(
        configApi,
        ['integrations.azure'],
        'dev.azure.com',
      ).map(host => ScmAuth.forAzure(azure, { host })),

      ...getConfiguredHosts(
        configApi,
        ['integrations.bitbucketCloud', 'integrations.bitbucket'],
        'bitbucket.org',
      ).map(host => ScmAuth.forBitbucket(bitbucket, { host })),

      ...getConfiguredHosts(configApi, ['integrations.bitbucketServer']).map(
        host =>
          ScmAuth.forBitbucketServer(bitbucketServer, {
            host,
            scopeMapping: {
              default: bitbucketServerDefaultScopes,
              repoWrite: bitbucketServerRepoWriteScopes,
            },
          }),
      ),
    ];

    return ScmAuth.merge(...providers);
  },
});

export const bitbucketServerScmAuthPlugin = createPlugin({
  id: 'bitbucket-server-scmauth',
  apis: [scmAuthApi],
});
```

#### File 4: `plugins/bitbucket-server-scmauth/src/index.ts`
```typescript
export { bitbucketServerScmAuthPlugin, scmAuthApi } from './plugin';
export { scmAuthApi as default } from './plugin';
```

#### File 5: Compile, Test, Export & Package with `@red-hat-developer-hub/cli@1.10.8`
Run the exact same RHDH CLI export/package steps used for Snyk and DX:
```bash
# 1. Install, type-check, test, and build TypeScript source
yarn install
yarn tsc
yarn --cwd plugins/bitbucket-server-scmauth test --watchAll=false
yarn --cwd plugins/bitbucket-server-scmauth build

# 2. Export RHDH 1.10 dynamic frontend bundle (generates dist-dynamic/ + dist-scalprum/)
cd plugins/bitbucket-server-scmauth
npx @red-hat-developer-hub/cli@1.10.8 plugin export

# 3A. Package as an OCI Artifact (Recommended — matches Snyk & DX workflow):
npx @red-hat-developer-hub/cli@1.10.8 plugin package \
  --tag quay.apps.example.com/rhdh/plugin-bitbucket-server-scmauth:0.1.0
podman push quay.apps.example.com/rhdh/plugin-bitbucket-server-scmauth:0.1.0

# 3B. Or Package as a .tgz Archive + sha512 Integrity Hash:
npm pack ./dist-dynamic --pack-destination ../../plugins/dist
INTEGRITY="sha512-$(openssl dgst -sha512 -binary ../../plugins/dist/internal-plugin-bitbucket-server-scmauth-dynamic-0.1.0.tgz | openssl base64 -A)"
echo "integrity: ${INTEGRITY}"
```

---

### 3.3 Delivering the Plugin in the Customer Environment (3 Supported Options)

In the customer OpenShift environment, RHDH's `install-dynamic-plugins` initContainer supports three ways to load the exported dynamic plugin:

<table>
  <thead>
    <tr>
      <th>Delivery Option</th>
      <th>How to Host It</th>
      <th><code>package:</code> Value in <code>dynamic-plugins.yaml</code></th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td><strong>Option A (Recommended): Internal OCI Container Registry (Quay / Artifactory Docker Registry — Same as Snyk &amp; DX)</strong></td>
      <td>Package with <code>npx @red-hat-developer-hub/cli@1.10.8 plugin package --tag quay.apps.example.com/rhdh/plugin-bitbucket-server-scmauth:0.1.0</code> and push to the internal OCI registry.</td>
      <td><code>oci://quay.apps.example.com/rhdh/plugin-bitbucket-server-scmauth:0.1.0!internal-plugin-bitbucket-server-scmauth</code><br><em>(no <code>integrity:</code> field needed for <code>oci://</code>)</em></td>
    </tr>
    <tr>
      <td><strong>Option B: Internal Artifact Repository (JFrog Artifactory / Nexus / Raw Git URL)</strong></td>
      <td>Upload <code>internal-plugin-bitbucket-server-scmauth-dynamic-0.1.0.tgz</code> (produced by <code>npm pack ./dist-dynamic</code>) to an internal generic/npm repo in Artifactory.</td>
      <td><code>https://artifactory.example.com/artifactory/rhdh-plugins/internal-plugin-bitbucket-server-scmauth-dynamic-0.1.0.tgz</code><br><em>(with <code>integrity: sha512-...</code>)</em></td>
    </tr>
    <tr>
      <td><strong>Option C: Local Volume Mount</strong></td>
      <td>Mount <code>internal-plugin-bitbucket-server-scmauth-dynamic-0.1.0.tgz</code> into the <code>install-dynamic-plugins</code> initContainer at <code>/opt/app-root/src/custom-plugins/internal-plugin-bitbucket-server-scmauth-dynamic-0.1.0.tgz</code>.</td>
      <td><code>/opt/app-root/src/custom-plugins/internal-plugin-bitbucket-server-scmauth-dynamic-0.1.0.tgz</code><br><em>(with <code>integrity: sha512-...</code>)</em></td>
    </tr>
  </tbody>
</table>

---

## 4. Complete RHDH Configuration Required in the Customer Environment

### 4.1 Environment Variables in `Secret/rhdh-secrets` (or ExternalSecret / Vault)

Add the following four keys to `rhdh-secrets`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: rhdh-secrets
  namespace: rhdh
type: Opaque
stringData:
  # 1. Bitbucket Data Center Hostname (hostname ONLY — no https:// prefix)
  BITBUCKET_SERVER_HOST: "bitbucket.example.com"

  # 2. Bitbucket Data Center Incoming Application Link (OAuth 2.0) Credentials
  BITBUCKET_OAUTH_CLIENT_ID: "<incoming-applink-client-id>"
  BITBUCKET_OAUTH_CLIENT_SECRET: "<incoming-applink-client-secret>"

  # 3. Bitbucket Data Center Service Account HTTP Access Token (for background catalog discovery)
  BITBUCKET_SERVER_TOKEN: "<service-account-http-access-token>"
```

---

### 4.2 `dynamic-plugins.yaml` (`ConfigMap/dynamic-plugins-rhdh`)

Enable the two Bitbucket Server backend modules (Scaffolder + Catalog) and the `internal.plugin-bitbucket-server-scmauth` frontend plugin:

```yaml
includes:
  - dynamic-plugins.default.yaml
plugins:
  # 1. Bitbucket Data Center Scaffolder Backend Actions (publish:bitbucketServer, publish:bitbucketServer:pull-request)
  - package: ./dynamic-plugins/dist/backstage-plugin-scaffolder-backend-module-bitbucket-server-dynamic
    disabled: false

  # 2. Bitbucket Data Center Catalog Provider Backend
  - package: ./dynamic-plugins/dist/backstage-plugin-catalog-backend-module-bitbucket-server-dynamic
    disabled: false

  # 3. Bitbucket Data Center ScmAuth Frontend API Factory (Enables RepoUrlPicker OAuth Popup)
  #    Option A — OCI Registry (same workflow as Snyk & DX; omit `integrity:`):
  - package: oci://quay.apps.example.com/rhdh/plugin-bitbucket-server-scmauth:0.1.0!internal-plugin-bitbucket-server-scmauth
    disabled: false
  #    (Or Option B — HTTP .tgz with sha512 integrity:
  #     package: https://artifactory.example.com/artifactory/rhdh-plugins/internal-plugin-bitbucket-server-scmauth-dynamic-0.1.0.tgz
  #     integrity: sha512-nuHTgkQj7TpQaN0BFQxZYNxEI/j1nyowS1coWGriY8OCeA8TN7n5XCDw9yKY/KHLRFFzfjbD1+CyQHQ6erJBPQ== )
    pluginConfig:
      dynamicPlugins:
        frontend:
          internal.plugin-bitbucket-server-scmauth:
            apiFactories:
              - importName: scmAuthApi
```
*(Note: If the customer cluster uses Red Hat's OCI plugin overlays instead of local `./dynamic-plugins/dist/...` paths, use `oci://ghcr.io/redhat-developer/rhdh-plugin-export-overlays/backstage-plugin-scaffolder-backend-module-bitbucket-server:bs_1.49.4__0.2.19` and `oci://ghcr.io/redhat-developer/rhdh-plugin-export-overlays/backstage-plugin-catalog-backend-module-bitbucket-server:bs_1.49.4__0.5.9`).*

---

### 4.3 `app-config.yaml` (`ConfigMap/app-config-rhdh`)

Configure **both** `auth.providers.bitbucketServer` (for interactive per-user OAuth 2.0) and `integrations.bitbucketServer` (for host matching + background catalog reading):

```yaml
backend:
  reading:
    allow:
      - host: ${BITBUCKET_SERVER_HOST}

auth:
  environment: production
  session:
    secret: "${BACKEND_SECRET}"
  providers:
    # 1. Interactive Per-User OAuth 2.0 Provider for Bitbucket Data Center
    # NOTE: Define both `development` and `production` environments under bitbucketServer
    # because Backstage's built-in defaultApis register bitbucketServerAuthApiRef with
    # defaultConfigGetter: () => "development" unless overridden.
    bitbucketServer:
      development:
        host: ${BITBUCKET_SERVER_HOST}
        clientId: ${BITBUCKET_OAUTH_CLIENT_ID}
        clientSecret: ${BITBUCKET_OAUTH_CLIENT_SECRET}
      production:
        host: ${BITBUCKET_SERVER_HOST}
        clientId: ${BITBUCKET_OAUTH_CLIENT_ID}
        clientSecret: ${BITBUCKET_OAUTH_CLIENT_SECRET}

integrations:
  # 2. Host Registration + Background Service Account for Catalog Ingestion
  # IMPORTANT: `scmAuthApi` reads `integrations.bitbucketServer[].host` at startup
  # to map RepoUrlPicker URLs to `bitbucketServerAuthApiRef`.
  bitbucketServer:
    - host: ${BITBUCKET_SERVER_HOST}
      apiBaseUrl: https://${BITBUCKET_SERVER_HOST}/rest/api/1.0
      token: ${BITBUCKET_SERVER_TOKEN}
```

> **Why both `development` and `production` are configured under `auth.providers.bitbucketServer`:**
> In Backstage's `@backstage/frontend-app-api` (`defaultApis.ts`), the built-in `bitbucketServerAuthApiRef` is instantiated with a default auth environment name unless explicitly overridden. Defining both `development:` and `production:` blocks with the same `${BITBUCKET_*}` variables guarantees `/api/auth/bitbucketServer/start?env=...` succeeds regardless of whether `auth.environment` is set to `production` or `development`.

---

### 4.4 Helm Chart `values.yaml` (If Deploying via `charts/developer-hub`)

If using the `charts/developer-hub` Helm chart in this repository, all of the above ConfigMap entries are rendered automatically by setting:

```yaml
app:
  readingAllow:
    - host: bitbucket.example.com

auth:
  environment: production
  bitbucketServer:
    enabled: true
    host: "${BITBUCKET_SERVER_HOST}"
    clientId: "${BITBUCKET_OAUTH_CLIENT_ID}"
    clientSecret: "${BITBUCKET_OAUTH_CLIENT_SECRET}"

integrations:
  bitbucketServer:
    enabled: true
    host: "${BITBUCKET_SERVER_HOST}"
    token: "${BITBUCKET_SERVER_TOKEN}"

plugins:
  bitbucket:
    enabled: true
    serverScaffolder: oci://ghcr.io/redhat-developer/rhdh-plugin-export-overlays/backstage-plugin-scaffolder-backend-module-bitbucket-server:bs_1.49.4__0.2.19
    serverCatalog: oci://ghcr.io/redhat-developer/rhdh-plugin-export-overlays/backstage-plugin-catalog-backend-module-bitbucket-server:bs_1.49.4__0.5.9
    # OCI package (same as Snyk & DX — chart automatically omits `integrity:` for oci:// URLs):
    serverScmAuthFrontendPackage: oci://quay.apps.example.com/rhdh/plugin-bitbucket-server-scmauth:0.1.0!internal-plugin-bitbucket-server-scmauth
    # Or if using HTTP .tgz instead of oci://:
    # serverScmAuthFrontendPackage: https://artifactory.example.com/artifactory/rhdh-plugins/internal-plugin-bitbucket-server-scmauth-dynamic-0.1.0.tgz
    # serverScmAuthFrontendIntegrity: sha512-nuHTgkQj7TpQaN0BFQxZYNxEI/j1nyowS1coWGriY8OCeA8TN7n5XCDw9yKY/KHLRFFzfjbD1+CyQHQ6erJBPQ==
```

---

## 5. Golden Path Software Template Configuration (`template.yaml`)

In your Golden Path Software Template:
1. Configure `ui:field: RepoUrlPicker` with `allowedHosts: [bitbucket.example.com]`.
2. Add `requestUserCredentials` with `secretsKey: USER_OAUTH_TOKEN` and `additionalScopes.bitbucket: [PROJECT_ADMIN, REPO_WRITE]`.
3. Pass `token: ${{ secrets.USER_OAUTH_TOKEN }}` to `publish:bitbucketServer` (and/or `publish:bitbucketServer:pull-request`).

```yaml
apiVersion: scaffolder.backstage.io/v1beta3
kind: Template
metadata:
  name: bitbucket-datacenter-golden-path
  title: Golden Path Service (Bitbucket Data Center)
  description: Scaffolds a new service repository in Bitbucket Data Center using the logged-in developer's OAuth 2.0 credentials
spec:
  owner: group:default/platform-team
  type: service

  parameters:
    - title: Repository Location
      required:
        - repoUrl
      properties:
        repoUrl:
          title: Bitbucket Data Center Repository Location
          type: string
          ui:field: RepoUrlPicker
          ui:options:
            allowedHosts:
              - bitbucket.example.com
            requestUserCredentials:
              secretsKey: USER_OAUTH_TOKEN
              additionalScopes:
                # ScmAuth uses key "bitbucket" (or "bitbucketServer") for custom scopes
                bitbucket:
                  - PROJECT_ADMIN
                  - REPO_WRITE

  steps:
    - id: fetch-skeleton
      name: Fetch Golden Path Skeleton
      action: fetch:template
      input:
        url: ./skeleton
        values:
          appName: ${{ (parameters.repoUrl | parseRepoUrl).repo }}

    # 1. Create New Repository & Push Skeleton as Logged-In User
    - id: publish-bitbucket
      name: Publish Repository to Bitbucket Data Center
      action: publish:bitbucketServer
      input:
        repoUrl: ${{ parameters.repoUrl }}
        description: "Golden Path Service created via Red Hat Developer Hub"
        defaultBranch: main
        repoVisibility: private
        # Uses the logged-in developer's OAuth 2.0 access token
        token: ${{ secrets.USER_OAUTH_TOKEN }}

    # 2. (Optional) Open a Pull Request on an Existing GitOps Repo as Logged-In User
    # Requires only REPO_WRITE + REPO_READ on the target repository
    - id: gitops-pr
      name: Open Pull Request in GitOps Repository
      action: publish:bitbucketServer:pull-request
      input:
        repoUrl: bitbucket.example.com?project=PLAT&repo=platform-gitops
        title: "chore(gitops): onboard ${{ (parameters.repoUrl | parseRepoUrl).repo }}"
        description: "Automated onboarding PR created by RHDH Golden Path"
        sourceBranch: "feat/onboard-${{ (parameters.repoUrl | parseRepoUrl).repo }}"
        targetBranch: main
        token: ${{ secrets.USER_OAUTH_TOKEN }}

  output:
    links:
      - title: Bitbucket Repository
        url: ${{ steps['publish-bitbucket'].output.remoteUrl }}
```

---

## 6. Verification & Troubleshooting Checklist in the Customer Environment

After applying the configuration and restarting the RHDH deployment:

1. **Verify the Dynamic Frontend Plugin Loaded (`install-dynamic-plugins` log)**:
   ```bash
   oc logs -n rhdh deploy/backstage-developer-hub -c install-dynamic-plugins | grep bitbucket-server-scmauth
   ```
   Expected output:
   ```text
   ======= Installing dynamic plugin https://.../internal-plugin-bitbucket-server-scmauth-dynamic-0.1.0.tgz
   ==> Successfully installed dynamic plugin https://.../internal-plugin-bitbucket-server-scmauth-dynamic-0.1.0.tgz
   ```

2. **Verify the Scaffolder Actions Registered (`backstage-backend` log)**:
   Open `https://<rhdh-route-hostname>/create/actions` in your browser and confirm that:
   - `publish:bitbucketServer`
   - `publish:bitbucketServer:pull-request`
   are listed.

3. **Verify the OAuth Handshake When Opening the Template**:
   When a developer opens the template in RHDH and fills in the **Project** and **Repository** fields under `RepoUrlPicker`:
   - RHDH backend logs will show:
     ```text
     GET /api/auth/bitbucketServer/refresh?optional&scope=PUBLIC_REPOS%20REPO_READ%20REPO_WRITE%20PROJECT_ADMIN&env=development HTTP/1.1 200
     ```
   - Clicking **Review / Next** triggers the Bitbucket Data Center OAuth popup (`/api/auth/bitbucketServer/start` → `https://bitbucket.example.com/rest/oauth2/latest/authorize`).
   - Once the developer clicks **Allow**, Bitbucket redirects back to `https://<rhdh-route-hostname>/api/auth/bitbucketServer/handler/frame`, and RHDH proceeds to the Review step with `secrets.USER_OAUTH_TOKEN` populated.
