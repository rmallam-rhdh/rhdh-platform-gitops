# RHDH 1.10: Bitbucket Data Center (Server) OAuth 2.0 & Golden Path Scaffolder Guide

## 1. Overview

In Red Hat Developer Hub (RHDH 1.10), when developers log in to RHDH using an enterprise SSO provider (such as Microsoft Entra ID / OIDC) and run a Golden Path Software Template to scaffold a new repository in **Bitbucket Data Center (Bitbucket Server)**, RHDH supports two authentication models:

<table>
  <thead>
    <tr>
      <th>Model</th>
      <th>How It Works</th>
      <th>Bitbucket Audit Trail &amp; Permissions</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td><strong>Per-User OAuth 2.0 (Recommended for Repo Creation)</strong></td>
      <td>Uses <code>auth.providers.bitbucketServer</code> + <code>requestUserCredentials</code> in the template's <code>RepoUrlPicker</code> to obtain the logged-in developer's personal Bitbucket OAuth token (<code>secrets.USER_OAUTH_TOKEN</code>).</td>
      <td>Repositories and commits are created under the <strong>logged-in developer's own Bitbucket identity</strong> and enforce their personal Bitbucket Project permissions.</td>
    </tr>
    <tr>
      <td><strong>Static Service Account (<code>integrations.bitbucketServer</code>)</strong></td>
      <td>Uses a shared Bitbucket HTTP Access Token configured in <code>app-config.yaml</code>.</td>
      <td>Required in the background for <strong>Catalog Discovery / Ingestion</strong> (<code>catalog-info.yaml</code> reads), where no interactive user browser session exists.</td>
    </tr>
  </tbody>
</table>

### Key Per-User OAuth Behaviors
1. **Prompted Only Once (First Run)**:
   - The first time a developer runs a Golden Path template, `RepoUrlPicker` opens a Bitbucket Data Center OAuth consent popup (`Allow`).
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

## 3. Enabling the Bitbucket Data Center OAuth Popup in RHDH 1.10 (`scmAuthApi` Dynamic Frontend Plugin)

### Why This Dynamic Frontend Plugin Is Required in RHDH 1.10
While RHDH 1.10 includes the built-in `RepoUrlPicker`, `BitbucketRepoPicker`, OAuth consent dialog, and `bitbucketServerAuthApiRef` (`core.auth.bitbucket-server`), RHDH 1.10's static `packages/app/src/apis.ts` only registers `github`, `gitlab`, `azure`, and `bitbucket` (Bitbucket Cloud) in `scmAuthApiRef` (`core.scmauth`) and omits `bitbucketServer`:

```typescript
// Default packages/app/src/apis.ts in RHDH 1.10 (missing bitbucketServer):
const providers = [
  { key: 'github', ref: github, factory: ScmAuth.forGithub },
  { key: 'gitlab', ref: gitlab, factory: ScmAuth.forGitlab },
  { key: 'azure', ref: azure, factory: ScmAuth.forAzure },
  { key: 'bitbucket', ref: bitbucket, factory: ScmAuth.forBitbucket },
];
```

Without overriding `scmAuthApiRef` (`core.scmauth`), using `requestUserCredentials` in `RepoUrlPicker` for a Bitbucket Data Center host throws:
`No auth provider available for 'https://bitbucket.example.com', see https://backstage.io/link?scm-auth`

In RHDH 1.10 (`DynamicRoot.tsx`), any dynamic frontend plugin that registers an `apiFactories` entry with `api.id === "core.scmauth"` automatically replaces the built-in static `scmAuthApiRef` factory.

### Directory Layout (Included in `plugins/bitbucket-server-scmauth/`)

```text
plugins/
├── bitbucket-server-scmauth/
│   ├── package.json
│   └── dist-scalprum/
│       ├── configSchema.json
│       ├── plugin-manifest.json
│       └── internal.plugin-bitbucket-server-scmauth.js
└── dist/
    └── internal-plugin-bitbucket-server-scmauth-dynamic-0.1.0.tgz
```

### Step-by-Step: How to Create and Package the Plugin From Scratch

#### Step 1: Create the Folder Structure
```bash
mkdir -p plugins/bitbucket-server-scmauth/dist-scalprum plugins/dist
```

#### Step 2: Create `plugins/bitbucket-server-scmauth/package.json`
```json
{
  "name": "@internal/plugin-bitbucket-server-scmauth-dynamic",
  "version": "0.1.0",
  "description": "RHDH 1.10 ScmAuth API Factory override adding Bitbucket Data Center (bitbucketServer) OAuth popup support to RepoUrlPicker",
  "license": "Apache-2.0",
  "main": "dist-scalprum/internal.plugin-bitbucket-server-scmauth.js",
  "files": [
    "dist-scalprum"
  ],
  "backstage": {
    "role": "frontend-plugin",
    "pluginId": "bitbucket-server-scmauth",
    "supported-versions": "1.49.4"
  }
}
```

#### Step 3: Create `plugins/bitbucket-server-scmauth/dist-scalprum/configSchema.json`
```json
{}
```

#### Step 4: Create `plugins/bitbucket-server-scmauth/dist-scalprum/plugin-manifest.json`
```json
{
  "name": "internal.plugin-bitbucket-server-scmauth",
  "version": "0.1.0",
  "extensions": [],
  "registrationMethod": "callback",
  "baseURL": "auto",
  "loadScripts": [
    "internal.plugin-bitbucket-server-scmauth.js"
  ],
  "buildHash": "bbserverscmauth010rhdh110"
}
```

#### Step 5: Create `plugins/bitbucket-server-scmauth/dist-scalprum/internal.plugin-bitbucket-server-scmauth.js`
```javascript
/* RHDH 1.10 ScmAuth API Factory Dynamic Frontend Plugin (Adds Bitbucket Data Center / bitbucketServer OAuth support) */
__load_plugin_entry__(
  "internal.plugin-bitbucket-server-scmauth",
  (function () {
    "use strict";

    function makeApiRef(id) {
      return {
        id: id,
        toString: function () {
          return "apiRef{" + id + "}";
        },
      };
    }

    var scmAuthApiRef = makeApiRef("core.scmauth");
    var githubAuthApiRef = makeApiRef("core.auth.github");
    var gitlabAuthApiRef = makeApiRef("core.auth.gitlab");
    var microsoftAuthApiRef = makeApiRef("core.auth.microsoft");
    var bitbucketAuthApiRef = makeApiRef("core.auth.bitbucket");
    var bitbucketServerAuthApiRef = makeApiRef("core.auth.bitbucket-server");
    var configApiRef = makeApiRef("core.config");

    function createScmAuthEntry(providerName, authApi, host, scopeMapping) {
      return {
        isUrlSupported: function (url) {
          return url && url.host === host;
        },
        getCredentials: function (options) {
          var additionalScope = (options && options.additionalScope) || {};
          var restOptions = {};
          if (options) {
            Object.keys(options).forEach(function (k) {
              if (k !== "url" && k !== "additionalScope") {
                restOptions[k] = options[k];
              }
            });
          }

          var scopes = (scopeMapping.default || []).slice();
          if (additionalScope.repoWrite && scopeMapping.repoWrite) {
            scopes.push.apply(scopes, scopeMapping.repoWrite);
          }

          var customScopes = additionalScope.customScopes || {};
          var extra =
            customScopes[providerName] ||
            (providerName === "bitbucketServer" ? customScopes.bitbucket : null) ||
            [];
          if (extra && extra.length) {
            scopes.push.apply(scopes, extra);
          }

          var uniqueScopes = [];
          scopes.forEach(function (s) {
            if (uniqueScopes.indexOf(s) === -1) {
              uniqueScopes.push(s);
            }
          });

          return Promise.resolve(authApi.getAccessToken(uniqueScopes, restOptions)).then(
            function (token) {
              return {
                token: token,
                headers: {
                  Authorization: "Bearer " + token,
                },
              };
            }
          );
        },
      };
    }

    function createScmAuthMux(providers) {
      return {
        getCredentials: function (options) {
          var url = new URL(options.url);
          var match = null;
          for (var i = 0; i < providers.length; i++) {
            if (providers[i].isUrlSupported(url)) {
              match = providers[i];
              break;
            }
          }
          if (!match) {
            return Promise.reject(
              new Error(
                "No auth provider available for '" +
                  options.url +
                  "', see https://backstage.io/link?scm-auth"
              )
            );
          }
          return match.getCredentials(options);
        },
      };
    }

    var SCOPE_MAPPINGS = {
      github: {
        defaultHost: "github.com",
        default: ["repo", "read:org", "read:user"],
        repoWrite: ["gist"],
      },
      gitlab: {
        defaultHost: "gitlab.com",
        default: ["read_user", "read_api", "read_repository"],
        repoWrite: ["write_repository", "api"],
      },
      azure: {
        defaultHost: "dev.azure.com",
        default: [
          "499b84ac-1321-427f-aa17-267ca6975798/vso.build",
          "499b84ac-1321-427f-aa17-267ca6975798/vso.code",
          "499b84ac-1321-427f-aa17-267ca6975798/vso.graph",
          "499b84ac-1321-427f-aa17-267ca6975798/vso.project",
          "499b84ac-1321-427f-aa17-267ca6975798/vso.profile",
        ],
        repoWrite: ["499b84ac-1321-427f-aa17-267ca6975798/vso.code_manage"],
      },
      bitbucket: {
        defaultHost: "bitbucket.org",
        default: ["account", "team", "pullrequest", "snippet", "issue", "project"],
        repoWrite: ["pullrequest:write", "snippet:write", "issue:write"],
      },
      bitbucketServer: {
        defaultHost: null,
        default: ["PUBLIC_REPOS", "REPO_READ"],
        repoWrite: ["REPO_WRITE", "PROJECT_ADMIN"],
      },
    };

    var scmAuthApi = {
      api: scmAuthApiRef,
      deps: {
        github: githubAuthApiRef,
        gitlab: gitlabAuthApiRef,
        azure: microsoftAuthApiRef,
        bitbucket: bitbucketAuthApiRef,
        bitbucketServer: bitbucketServerAuthApiRef,
        configApi: configApiRef,
      },
      factory: function (deps) {
        var providerDefs = [
          { key: "github", ref: deps.github, mapping: SCOPE_MAPPINGS.github },
          { key: "gitlab", ref: deps.gitlab, mapping: SCOPE_MAPPINGS.gitlab },
          { key: "azure", ref: deps.azure, mapping: SCOPE_MAPPINGS.azure },
          { key: "bitbucket", ref: deps.bitbucket, mapping: SCOPE_MAPPINGS.bitbucket },
          {
            key: "bitbucketServer",
            ref: deps.bitbucketServer,
            mapping: SCOPE_MAPPINGS.bitbucketServer,
          },
        ];

        var entries = [];
        providerDefs.forEach(function (def) {
          var configs =
            deps.configApi.getOptionalConfigArray("integrations." + def.key) || [];
          if (!configs.length) {
            if (def.mapping.defaultHost) {
              entries.push(
                createScmAuthEntry(def.key, def.ref, def.mapping.defaultHost, def.mapping)
              );
            }
            return;
          }
          configs.forEach(function (c) {
            var host = c.getString("host");
            entries.push(createScmAuthEntry(def.key, def.ref, host, def.mapping));
          });
        });

        return createScmAuthMux(entries);
      },
    };

    var exportedModule = {
      __esModule: true,
      default: scmAuthApi,
      scmAuthApi: scmAuthApi,
    };

    return {
      init: function () {
        return Promise.resolve();
      },
      get: function (module) {
        if (module === "PluginRoot" || module === "./PluginRoot" || module === ".") {
          return Promise.resolve(function () {
            return exportedModule;
          });
        }
        return Promise.reject(new Error("Unknown exposed module: " + module));
      },
    };
  })()
);
```

#### Step 6: Package the `.tgz` Archive & Compute the `sha512` Integrity Hash
```bash
npm pack ./plugins/bitbucket-server-scmauth --pack-destination ./plugins/dist

echo "integrity: sha512-$(openssl dgst -sha512 -binary plugins/dist/internal-plugin-bitbucket-server-scmauth-dynamic-0.1.0.tgz | openssl base64 -A)"
```
*(The pre-built archive is already committed at `plugins/dist/internal-plugin-bitbucket-server-scmauth-dynamic-0.1.0.tgz` with integrity `sha512-ZBCQBwqz7fOK3Y8k3o+Phk8uLZrJwSckcskV+zJOiC5kbj/rJ4Wmbgi9apwb3Q1aLdpYN6+Uo3lVUtcUVOKZ1w==`).*

---

## 4. RHDH Configuration (`dynamic-plugins.yaml` & `app-config.yaml`)

### A. Dynamic Plugins (`dynamic-plugins.yaml`)
Enable the Bitbucket Server Scaffolder/Catalog backend plugins **and** the `internal-plugin-bitbucket-server-scmauth-dynamic` frontend plugin:

```yaml
plugins:
  - package: ./dynamic-plugins/dist/backstage-plugin-scaffolder-backend-module-bitbucket-server-dynamic
    disabled: false
  - package: ./dynamic-plugins/dist/backstage-plugin-catalog-backend-module-bitbucket-server-dynamic
    disabled: false
  # Enables Bitbucket Data Center (bitbucketServer) OAuth popup in RepoUrlPicker
  - package: https://raw.githubusercontent.com/rmallam-rhdh/rhdh-platform-gitops/main/plugins/dist/internal-plugin-bitbucket-server-scmauth-dynamic-0.1.0.tgz
    integrity: sha512-ZBCQBwqz7fOK3Y8k3o+Phk8uLZrJwSckcskV+zJOiC5kbj/rJ4Wmbgi9apwb3Q1aLdpYN6+Uo3lVUtcUVOKZ1w==
    disabled: false
    pluginConfig:
      dynamicPlugins:
        frontend:
          internal.plugin-bitbucket-server-scmauth:
            apiFactories:
              - importName: scmAuthApi
```
*(In a disconnected/air-gapped environment, host `internal-plugin-bitbucket-server-scmauth-dynamic-0.1.0.tgz` on JFrog Artifactory or package it as an OCI image layer just like other custom plugins).*

### B. `app-config.yaml` (`auth.providers.bitbucketServer` & `integrations.bitbucketServer`)

```yaml
auth:
  environment: production
  providers:
    # 1. Interactive Per-User OAuth 2.0 Provider for Bitbucket Data Center
    bitbucketServer:
      production:
        host: ${BITBUCKET_SERVER_HOST} # e.g. bitbucket.example.com (hostname only, no https://)
        clientId: ${BITBUCKET_OAUTH_CLIENT_ID}
        clientSecret: ${BITBUCKET_OAUTH_CLIENT_SECRET}

integrations:
  # 2. Host Registration + Background Service Account for Catalog Ingestion
  # (The host entry under integrations.bitbucketServer is also read by scmAuthApi to match RepoUrlPicker URLs)
  bitbucketServer:
    - host: ${BITBUCKET_SERVER_HOST} # e.g. bitbucket.example.com
      apiBaseUrl: https://${BITBUCKET_SERVER_HOST}/rest/api/1.0
      token: ${BITBUCKET_SERVER_TOKEN}
```

*(Optionally, you can also set `scaffolder.requireScmUserCredentials: true` in `app-config.yaml` if you want `publish:bitbucketServer` to strictly require a user OAuth token and never fall back to `integrations.bitbucketServer[].token`).*

---

## 5. Golden Path Software Template Configuration (`template.yaml`)

By default, Backstage's `ScmAuth.forBitbucketServer` (`@backstage/integration-react`) requests `["PUBLIC_REPOS", "REPO_READ", "REPO_WRITE"]`. To ensure the OAuth token issued during the template run also includes `PROJECT_ADMIN` for repository creation, declare `PROJECT_ADMIN` under `requestUserCredentials.additionalScopes.bitbucket`:

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
                # ScmAuth.forBitbucketServer uses provider key "bitbucket" internally
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
