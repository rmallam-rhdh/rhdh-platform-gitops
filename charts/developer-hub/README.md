# Developer Hub Helm chart

GitOps package for **Red Hat Developer Hub 1.10**: Backstage CR, dynamic plugins, app-config, RBAC CSV, and secret wiring.

This chart **does include Microsoft Entra ID (Azure AD) sign-in**, plus LDAP catalog sync so Entra users resolve to `user:default/<uid>` (not an email-shaped identity). It does **not** store client secrets in git.

Nothing in `charts/` is committed or pushed until you ask. The live ROSA instance is already running from a local `helm upgrade --install rhdh` (release `rhdh` in namespace `rhdh`).

## What is in the chart vs what is not

| Included | Not included (leave as-is on the cluster) |
|---|---|
| Backstage CR, app-config, dynamic plugins, RBAC CSV | RHDH **operator** on ROSA (already in `rhdh-operator`, channel `fast-1.10`) |
| Microsoft Entra **login** (`auth.providers.microsoft`) | Entra **app registration** in Azure Portal (you create this) |
| LDAP org catalog (`catalog.providers.ldapOrg`) | OpenLDAP deployment (`demo/ldap/` is separate) |
| Sign-in resolvers (email → LDAP user, then local-part fallback) | Secret values (`AZURE_*`, `LDAP_BIND_PASSWORD`, …) |
| Plugin enable flags + OCI pins (Jenkins, Argo, Snyk, Jira, Vault, …) | Bitbucket **SaaS** (overlay module still broken) |
| CNPG `Cluster` + Hub `backend.database` | CNPG **operator** (`components/cnpg`, ns `cnpg-system`) |
| Guest login (demo overlay only) | Istio/mesh CRs (`components/developer-hub/base/service-mesh`) |

MS Graph **catalog sync** (`plugins.msgraph` / `catalog.msgraph`) is **off** by default. Identities come from LDAP; Entra is the login provider. Turn Graph on only when you have tenant-wide User.Read.All and want Entra groups in the catalog.

## Files

| File | Role |
|---|---|
| `values.yaml` | Customer defaults: Entra + LDAP, ESO secrets, production `signInPage` |
| `values-demo.yaml` | ROSA lab: guest + Entra, CNPG, ESO secrets, `operator.enabled: false` |
| `argocd/apps/developer-hub.yaml` | Argo CD → Helm + `values.yaml` |
| `argocd/apps/developer-hub-demo.yaml` | Argo CD → Helm + demo overlay |

Operators and tools already exist, deploy **only** the Hub instance: see [DEPLOY-RHDH-ONLY.md](DEPLOY-RHDH-ONLY.md) (URL fields, Vault env map, `values-cluster.yaml`).

## 1. Change these values for a new cluster

Copy `values.yaml` (or overlay `values-demo.yaml`) and set:

### Cluster / URL

```yaml
app:
  title: Acme Developer Hub
  organization: Acme
  clusterBaseDomain: apps.<cluster>.openshiftapps.com
  baseUrl: https://backstage-developer-hub-rhdh.apps.<cluster>.openshiftapps.com
```

`baseUrl` **must** match the OpenShift route. Entra redirect URIs are derived from it (see below).

### Operator

- **Greenfield:** `operator.enabled: true`, `operator.channel: fast-1.10`
- **This ROSA lab:** keep `operator.enabled: false` — a second Subscription in `rhdh` would fight the existing operator in `rhdh-operator`

### Entra (Microsoft) login — required

In Azure Portal create an **App registration** (single tenant):

1. **Redirect URI** (Web):  
   `{baseUrl}/api/auth/microsoft/handler/frame`  
   Example on this ROSA cluster:  
   `https://backstage-developer-hub-rhdh.apps.rosa.rosa-89s85.bhg0.p3.openshiftapps.com/api/auth/microsoft/handler/frame`
2. Create a **client secret**. Put ID / secret / tenant into `rhdh-secrets` (never into values).
3. API permissions: `openid`, `profile`, `email`, `User.Read` (delegated). Admin consent if the tenant requires it.

Then in values:

```yaml
auth:
  environment: production          # use development only if guest login is required
  signInPage:
    - microsoft                    # add guest under values-demo.yaml only
  microsoft:
    enabled: true
    domainHint: <your-tenant>.onmicrosoft.com   # e.g. acme.onmicrosoft.com
    clientId: "${AZURE_CLIENT_ID}"
    clientSecret: "${AZURE_CLIENT_SECRET}"
    tenantId: "${AZURE_TENANT_ID}"
```

The chart always emits **both** `development` and `production` Microsoft provider blocks (RHDH picks by `auth.environment`). Resolvers:

1. `emailMatchingUserEntityProfileEmail` — Entra **mail** must equal LDAP `mail`
2. `emailLocalPartMatchingUserEntityName` — fallback (e.g. `alice@…` → `user:default/alice`)

Do **not** set `dangerouslyAllowSignInWithoutUserInCatalog` on the first resolver. That mints `user:default/alice@onmicrosoft.com`, which RBAC cannot bind.

### LDAP catalog — required for Entra users to see templates/groups

Entra authenticates; LDAP is the catalog of users/groups. Join key is **email**.

```yaml
catalog:
  ldap:
    enabled: true
    target: ldap://openldap.ldap.svc.cluster.local:389
    bindDn: cn=admin,dc=acme,dc=demo
    bindSecret: "${LDAP_BIND_PASSWORD}"
    usersDn: ou=people,dc=acme,dc=demo
    groupsDn: ou=groups,dc=acme,dc=demo
```

Each LDAP person needs `mail` equal to the Entra user’s email (UPN is not enough if they differ). Demo users: alice / bob / carol — alice’s Entra UPN was `alice@…` while LDAP mail is Gmail; the second resolver covers that.

Guest (`auth.guest.enabled`) is **demo-only**. Production values keep it off.

### Secrets

Values never contain real credentials. RHDH substitutes `${AZURE_CLIENT_ID}` from Secret `rhdh-secrets`.

| `secrets.mode` | When to use |
|---|---|
| `external` | Secret already exists (this ROSA cluster). Chart does not create or overwrite it. |
| `eso` | Vault + External Secrets Operator (`values.yaml` default). Seed Vault paths listed under `secrets.keys`. |
| `placeholder` | Empty lab only. Dummy stringData — never for Entra. |

Minimum keys for Entra + LDAP + GitHub catalog:

```
AZURE_CLIENT_ID
AZURE_CLIENT_SECRET
AZURE_TENANT_ID
BACKEND_SECRET
LDAP_BIND_PASSWORD
GITHUB_TOKEN          # catalog locations on GitHub
```

Create or patch (do not commit the result):

```bash
oc -n rhdh create secret generic rhdh-secrets \
  --from-literal=AZURE_CLIENT_ID='…' \
  --from-literal=AZURE_CLIENT_SECRET='…' \
  --from-literal=AZURE_TENANT_ID='…' \
  --from-literal=BACKEND_SECRET='…' \
  --from-literal=LDAP_BIND_PASSWORD='…' \
  --from-literal=GITHUB_TOKEN='…'
```

On this cluster the secret already exists; `values-demo.yaml` uses `secrets.mode: external`.

### Plugins / tools

Each plugin has `enabled` plus package URI and URLs. Placeholders (`https://jenkins.example.invalid`) let the Hub **start** before the tool exists. Replace with real URLs and tokens when you install each tool.

| Plugin | Demo (`values-demo.yaml`) | To go live |
|---|---|---|
| Snyk | OCI `ghcr.io/rmallam/rhdh-plugin-snyk:bs_1.49.4__2.5.10`, `mocked: true` | Real `SNYK_TOKEN` + org; make the GHCR package **public** or keep Secret `dynamic-plugins-registry-auth` |
| Vault | `enabled: false` (no GA overlay tag) | Flip when a `bs_` tag exists |
| Bitbucket | `enabled: false` | Official OCI tags already in `values.yaml` |
| Keycloak / MS Graph catalog | `enabled: false` | Needs extra config; Entra login does not need them |
| Jenkins, Argo, Jira, Artifactory, SNOW, Dynatrace, APIC | on, stub URLs | Set `plugins.<name>.*` + secret keys |

Private GHCR (Snyk image): the operator already mounts optional Secret `dynamic-plugins-registry-auth` (`auth.json` for `ghcr.io`). That secret is **not** in the chart.

### RBAC

Admins must be objects (`name: user:default/bob`), not bare strings. Bind LDAP uids (`alice`, `bob`, `carol`) in `permission.policiesCsv`. Email-shaped entity names (`alice@…`) cannot be listed in the CSV.

## 2. Apply

```bash
# 1) CNPG operator (once per cluster) — see docs/rhdh-cnpg/README.md
oc apply -k components/cnpg/base

# 2) Lab / this ROSA cluster (does not touch the RHDH operator Subscription)
helm upgrade --install rhdh charts/developer-hub -n rhdh \
  --take-ownership --force-conflicts \
  -f charts/developer-hub/values.yaml \
  -f charts/developer-hub/values-demo.yaml

charts/developer-hub/tests/test-chart.sh
components/cnpg/tests/test-manifests.sh
```

After Entra secret or `domainHint` / `baseUrl` changes, users must **sign out and sign in again** so resolvers re-run.

## 3. Checklist if Microsoft login sees an empty catalog

1. Entra redirect URI matches `{baseUrl}/api/auth/microsoft/handler/frame`
2. `AZURE_*` keys exist on `rhdh-secrets` and the Backstage CR `extraEnvs.secrets` is `rhdh-secrets`
3. LDAP user `mail` matches the Entra profile email (or local-part matches `uid`)
4. Sign out completely (or private window) — old sessions may still be `user:default/alice@…`
5. Guest templates are owned by `user:default/guest`; Microsoft users see them only if RBAC allows (developer role in the CSV)

## Database (CloudNativePG)

The bundled `backstage-psql-*` pod is **not** the customer target. Operator install is separate (`components/cnpg`); the Helm chart owns the `Cluster` and points the Backstage CR at it.

Full reuse playbook (pins, values, secret map, install order, verify): [docs/rhdh-cnpg/README.md](../../docs/rhdh-cnpg/README.md). Demo overlay: `enableLocalDb: false`, Cluster `rhdh-pg`, credentials from Secret `rhdh-pg-app`.

## Plugin runbooks

Per-plugin requirements, secrets, annotations, and known issues (update when a tab fails or a fix lands):

[docs/rhdh-plugins/README.md](../../docs/rhdh-plugins/README.md)

Demo fixture: catalog entity `plugin-kitchen-sink`. Templates: `acme-plugin-kitchen-sink` (plugin tabs) and `acme-nodejs-golden-path` (Jenkins + Helm + Sonar + Dev Spaces).

## Tests

```bash
charts/developer-hub/tests/test-chart.sh
```
