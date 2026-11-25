# RHDH 1.10: Bitbucket Data Center (Server) OAuth 2.0 & Golden Path Scaffolder Guide

## 1. Overview

In Red Hat Developer Hub (RHDH 1.10), when developers log in to RHDH using an enterprise SSO provider (such as Microsoft Entra ID / OIDC) and run a Golden Path Software Template to scaffold a new repository in **Bitbucket Data Center (Bitbucket Server)**, RHDH supports two authentication models:

| Model | How It Works | Bitbucket Audit Trail & Permissions |
| :--- | :--- | :--- |
| **Per-User OAuth 2.0 (Recommended for Repo Creation)** | Uses `auth.providers.bitbucketServer` + `requestUserCredentials` in the template's `RepoUrlPicker` to obtain the logged-in developer's personal Bitbucket OAuth token (`secrets.USER_OAUTH_TOKEN`). | Repositories and commits are created under the **logged-in developer's own Bitbucket identity** and enforce their personal Bitbucket Project permissions. |
| **Static Service Account (`integrations.bitbucketServer`)** | Uses a shared Bitbucket HTTP Access Token configured in `app-config.yaml`. | Required in the background for **Catalog Discovery / Ingestion** (`catalog-info.yaml` reads), where no interactive user browser session exists. |

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

| Bitbucket Data Center Scope Name | RHDH / API Scope ID | Required? | Why RHDH Requires This Scope |
| :--- | :--- | :--- | :--- |
| **Project Admin** | `PROJECT_ADMIN` | **Yes (Required to create repos)** | `publish:bitbucketServer` calls `POST /rest/api/1.0/projects/{projectKey}/repos`. In Bitbucket Data Center's REST API permission model, creating a new repository inside a Bitbucket Project requires `PROJECT_ADMIN` (Repository Write alone only allows pushing to an *existing* repo). |
| **Repository Admin** | `REPO_ADMIN` | **Yes** *(included with Project Admin)* | Required if the template enables Git LFS (`PUT /rest/git-lfs/admin/projects/{project}/repos/{repo}/enabled`), configures branch permissions, or manages webhooks. |
| **Repository Write** | `REPO_WRITE` | **Yes** | Requested by Backstage `ScmAuth.forBitbucketServer` (`repoWrite: true`) to push the initial Golden Path skeleton commit (`git push`) and to open Pull Requests (`publish:bitbucketServer:pull-request`). |
| **Repository Read** | `REPO_READ` | **Yes** | Requested by `ScmAuth.forBitbucketServer` default scopes (`["PUBLIC_REPOS", "REPO_READ"]`) so `BitbucketRepoPicker` can list available projects, repositories, and branches in the template UI. |
| **Public Repositories** | `PUBLIC_REPOS` | **Yes** | Hardcoded in Backstage's `ScmAuth.forBitbucketServer` default scope list (`["PUBLIC_REPOS", "REPO_READ"]`). If this checkbox is not enabled on the Bitbucket Application Link, Bitbucket rejects the OAuth popup with `invalid_scope`. |

> **Important Note on User Permissions in Bitbucket Data Center:**
> OAuth 2.0 delegates the intersection of the **Application Link scopes** and the **logged-in user's own Bitbucket permissions**. An OAuth app with `PROJECT_ADMIN` does **not** elevate a read-only user to admin — the developer running the template must also have permission in Bitbucket Data Center to create repositories in the target Bitbucket Project (or, if developers do not have Project Admin rights in Bitbucket, repo creation can fall back to a dedicated service account token while PR creation uses the developer's OAuth token).

---

## 3. RHDH Configuration (`app-config.yaml` & `dynamic-plugins.yaml`)

### A. Dynamic Plugins (`dynamic-plugins.yaml`)
RHDH 1.10 includes `@backstage/plugin-auth-backend-module-bitbucket-server-provider` built into core (`authProvidersModule.cjs.js`). Enable the Bitbucket Server Scaffolder and Catalog backend dynamic plugins:

```yaml
plugins:
  - package: ./dynamic-plugins/dist/backstage-plugin-scaffolder-backend-module-bitbucket-server-dynamic
    disabled: false
  - package: ./dynamic-plugins/dist/backstage-plugin-catalog-backend-module-bitbucket-server-dynamic
    disabled: false
```

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
  # 2. Background Service Account for Catalog Ingestion & Fallback
  bitbucketServer:
    - host: ${BITBUCKET_SERVER_HOST} # e.g. bitbucket.example.com
      apiBaseUrl: https://${BITBUCKET_SERVER_HOST}/rest/api/1.0
      token: ${BITBUCKET_SERVER_TOKEN}
```

*(Optionally, you can also set `scaffolder.requireScmUserCredentials: true` in `app-config.yaml` if you want `publish:bitbucketServer` to strictly require a user OAuth token and never fall back to `integrations.bitbucketServer[].token`).*

---

## 4. Golden Path Software Template Configuration (`template.yaml`)

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
