# Deploy only the RHDH instance (operators and tools already exist)

Use **`values.yaml`**, not `values-demo.yaml`. The demo overlay is pinned to ROSA `rosa-89s85`.

Assumption: RHDH operator, ESO, Vault (KV v2), Postgres (or you use the bundled DB), Jenkins, Sonar, GitOps, Kiali, and SaaS tools already exist. This chart only creates the Backstage CR, plugin ConfigMaps, RBAC, and ExternalSecret.

Install:

```bash
helm upgrade --install rhdh charts/developer-hub \
  --namespace rhdh \
  -f charts/developer-hub/values.yaml \
  -f charts/developer-hub/values-cluster.yaml
```

Put cluster-specific URL and flag overrides in `values-cluster.yaml` (do not commit secrets).

Vault layout this chart expects:

```text
<kv-mount>/rhdh/<vault-key>
  value: <string>
```

Lab mount is `secrets`. ESO maps `rhdh/<vault-key>` property `value` → Kubernetes Secret `rhdh-secrets` env `<ENV>`.

---

## 1. Where tool URLs are set

Two places. Do not mix them up.

| What | Where you set it |
|---|---|
| Hub’s own public URL | Helm `app.baseUrl` and `app.clusterBaseDomain` |
| Plugin → Jenkins / Jira / Vault / … | **Vault** (because `values.yaml` uses `${ENV}`) |
| Hosts Hub is allowed to call | Helm `app.readingAllow` (must list every SaaS hostname) |
| Path those calls take (direct vs corporate proxy) | [Corporate HTTP proxy](#4-corporate-http-proxy-for-saas-calls) |
| Which Jira project / Dynatrace service an *app* shows | That app’s `catalog-info.yaml`, not the chart |

### Helm — Hub URL (required)

`charts/developer-hub/values.yaml` (or `values-cluster.yaml`):

```yaml
app:
  clusterBaseDomain: apps.YOURCLUSTER.openshiftapps.com
  baseUrl: https://backstage-developer-hub-rhdh.apps.YOURCLUSTER.openshiftapps.com
```

Entra redirect URI is `{baseUrl}/api/auth/microsoft/handler/frame`.

### Helm — allowlist (required for SaaS)

`app.readingAllow` in the same file. Add a `host:` entry for every tool Hub will HTTP-call. `values.yaml` only has GitHub / Microsoft / Snyk / Bitbucket. You must add yours, for example:

```yaml
app:
  readingAllow:
    - host: github.com
    - host: raw.githubusercontent.com
    - host: api.github.com
    - host: login.microsoftonline.com
    - host: graph.microsoft.com
    - host: YOUR.atlassian.net          # Jira Cloud
    - host: xxxx.apps.dynatrace.com     # Dynatrace UI
    - host: xxxx.live.dynatrace.com     # Dynatrace API
    - host: sso.dynatrace.com
    - host: kiali-istio-system.apps.YOURCLUSTER.openshiftapps.com
```

In-cluster tools (`jenkins.jenkins.svc`, `sonarqube.sonarqube.svc`, `vault.vault.svc`) do not need to be listed.

### Vault — plugin connection URLs

`values.yaml` already points plugins at env vars. **Put the URL in Vault**, not in the chart:

| Plugin | Helm field (do not change) | Env in `rhdh-secrets` | Vault path | Example value |
|---|---|---|---|---|
| Jenkins | `plugins.jenkins.instances[0].baseUrl` | `JENKINS_BASE_URL` | `rhdh/jenkins-base-url` | `http://jenkins.jenkins.svc` |
| Argo CD | `plugins.argocd.instances[0].url` | `ARGOCD_URL` | `rhdh/argocd-url` | `https://openshift-gitops-server-openshift-gitops.apps.YOURCLUSTER.openshiftapps.com` |
| SonarQube | `plugins.sonarqube.baseUrl` | `SONARQUBE_BASE_URL` | `rhdh/sonarqube-base-url` | `http://sonarqube.sonarqube.svc:9000` |
| Jira | `plugins.jira.baseUrl` | `JIRA_BASE_URL` | `rhdh/jira-base-url` | `https://YOUR.atlassian.net` |
| Vault plugin | `plugins.vault.baseUrl` | `VAULT_ADDR` | `rhdh/vault-addr` | `http://vault.vault.svc:8200` |
| Kiali | `plugins.kiali.url` | `KIALI_URL` | `rhdh/kiali-url` | `https://kiali.istio-system.svc:20001` |
| Dynatrace UI | `plugins.dynatrace.url` | `DYNATRACE_URL` | `rhdh/dynatrace-url` | `https://xxxx.apps.dynatrace.com` |
| ServiceNow | `plugins.servicenow.baseUrl` | `SERVICENOW_BASE_URL` | `rhdh/servicenow-base-url` | real URL or stub |
| Artifactory | `plugins.artifactory.baseUrl` | `ARTIFACTORY_BASE_URL` | `rhdh/artifactory-base-url` | real URL or stub |
| APIC | `plugins.apic.baseUrl` / `url` | `APIC_BASE_URL` / `APIC_API_URL` | `rhdh/apic-base-url` / `rhdh/apic-api-url` | real URL or stub |
| Kubernetes API | `plugins.kubernetes.url` | `KUBE_API_URL` | `rhdh/kube-api-url` | `https://kubernetes.default.svc` |

If Jira’s site changes later: update Vault `rhdh/jira-base-url` **and** `app.readingAllow`. Do not hunt through plugin YAML.

### Helm — two URL fields that Vault does not cover

Set these in `values-cluster.yaml`:

```yaml
plugins:
  kubernetes:
    clusterName: YOURCLUSTER          # display name only
  dynatrace:
    # Classic problems API (not the apps UI host)
    apiTarget: https://xxxx.live.dynatrace.com/api/v2
  jira:
    product: cloud                    # or leave empty for Jira DC
    authorization: "${JIRA_TOKEN}"    # Cloud. Omit for DC (Bearer)
```

LDAP URL (if you keep LDAP catalog): `catalog.ldap.target`.

---

## 2. Secrets to push (Vault key → env var)

Every row becomes one key in Secret `rhdh-secrets`. ESO field is `secretKey` = **Env**. Vault object is `secrets/rhdh/<Vault key>` with property **`value`**.

```bash
vault kv put secrets/rhdh/jira-token value='…'
```

### Must have (Hub process)

| Env (`rhdh-secrets`) | Vault key | What to put |
|---|---|---|
| `BACKEND_SECRET` | `backend-secret` | random hex, 32+ bytes |
| `AUTH_SESSION_SECRET` | `auth-session-secret` | random hex, 32+ bytes |
| `GITHUB_TOKEN` | `github-token` | PAT that can create repos + read catalog |

### Login (Entra)

| Env | Vault key | What to put |
|---|---|---|
| `AZURE_TENANT_ID` | `azure-tenant-id` | Directory (tenant) ID |
| `AZURE_CLIENT_ID` | `azure-client-id` | App registration client ID |
| `AZURE_CLIENT_SECRET` | `azure-client-secret` | App registration secret |

Skip these three only if you turn Microsoft login off.

### In-cluster tools

| Env | Vault key | What to put |
|---|---|---|
| `JENKINS_BASE_URL` | `jenkins-base-url` | `http://jenkins.jenkins.svc` |
| `JENKINS_USERNAME` | `jenkins-username` | Jenkins user |
| `JENKINS_API_TOKEN` | `jenkins-api-token` | Jenkins API token |
| `JENKINS_BASIC_AUTH_B64` | `jenkins-basic-auth-b64` | `base64(username:apiToken)` |
| `SONARQUBE_BASE_URL` | `sonarqube-base-url` | `http://sonarqube.sonarqube.svc:9000` |
| `SONARQUBE_API_KEY` | `sonarqube-api-key` | Sonar token |
| `ARGOCD_URL` | `argocd-url` | GitOps server URL (see table in §1) |
| `ARGOCD_TOKEN` | `argocd-token` | Argo CD bearer token |
| `VAULT_ADDR` | `vault-addr` | URL **Hub pods** use to reach Vault |
| `VAULT_TOKEN` | `vault-list-token` | Token for the **Vault plugin tab** (LIST on `secrets/metadata/rhdh`, not ESO’s token) |
| `KIALI_URL` | `kiali-url` | In-cluster `https://kiali.istio-system.svc:20001` (axios skips Squid via `.svc`) |
| `KUBE_API_URL` | `kube-api-url` | `https://kubernetes.default.svc` |
| `KUBE_SA_TOKEN` | `kube-sa-token` | empty if Hub uses in-cluster SA (`values-demo` does this) |
| `KUBE_CA_DATA` | `kube-ca-data` | empty if in-cluster |
| `CLUSTER_BASE_DOMAIN` | `cluster-base-domain` | `apps.YOURCLUSTER.openshiftapps.com` |

### SaaS

| Env | Vault key | What to put |
|---|---|---|
| `JIRA_BASE_URL` | `jira-base-url` | `https://YOUR.atlassian.net` |
| `JIRA_TOKEN` | `jira-token` | **Cloud:** `Basic ` + base64(`email:apiToken`). **DC:** the PAT (chart sends Bearer unless you set `plugins.jira.authorization`) |
| `DYNATRACE_URL` | `dynatrace-url` | `https://xxxx.apps.dynatrace.com` |
| `DYNATRACE_ACCESS_TOKEN` | `dynatrace-access-token` | classic token `dt0c01.…` with `entities.read` + `problems.read` |
| `DYNATRACE_CLIENT_ID` | `dynatrace-client-id` | OAuth client, or `stub` if no DQL |
| `DYNATRACE_CLIENT_SECRET` | `dynatrace-client-secret` | OAuth secret, or `stub` |
| `DYNATRACE_ACCOUNT_URN` | `dynatrace-account-urn` | `urn:dtaccount:…`, or `stub` |

### Unused plugins (still required — ESO fails if a key is missing)

| Env | Vault key | Safe stub |
|---|---|---|
| `SNYK_TOKEN` | `snyk-token` | `stub` (or set `plugins.snyk.mocked: true`) |
| `SNYK_ORG_SLUG` | `snyk-org-slug` | `stub` |
| `ARTIFACTORY_BASE_URL` | `artifactory-base-url` | stub base URL |
| `ARTIFACTORY_TOKEN` | `artifactory-token` | `stub` |
| `SERVICENOW_BASE_URL` | `servicenow-base-url` | stub base URL |
| `SERVICENOW_USERNAME` | `servicenow-username` | `stub` |
| `SERVICENOW_PASSWORD` | `servicenow-password` | `stub` |
| `APIC_BASE_URL` | `apic-base-url` | stub |
| `APIC_API_URL` | `apic-api-url` | stub |
| `APIC_API_KEY` | `apic-api-key` | `stub` |
| `APIC_CLIENT_ID` | `apic-client-id` | `stub` |
| `APIC_SECRET` | `apic-secret` | `stub` |
| `BITBUCKET_USERNAME` | `bitbucket-username` | `stub` |
| `BITBUCKET_APP_PASSWORD` | `bitbucket-app-password` | `stub` |
| `BITBUCKET_SERVER_HOST` | `bitbucket-server-host` | `bitbucket.example.invalid` |
| `BITBUCKET_SERVER_TOKEN` | `bitbucket-server-token` | `stub` |
| `LDAP_BIND_PASSWORD` | `ldap-bind-password` | real bind password, or `stub` if you disable LDAP |
| `OAUTH_CLIENT_ID` | `oauth-client-id` | `stub` (OIDC login is off) |
| `OAUTH_CLIENT_SECRET` | `oauth-client-secret` | `stub` |
| `GITHUB_OAUTH_CLIENT_ID` | `github-oauth-client-id` | `stub` (GitHub login is off) |
| `GITHUB_OAUTH_CLIENT_SECRET` | `github-oauth-client-secret` | `stub` |
| `KEYCLOAK_PLUGIN_CLIENT_ID` | `keycloak-plugin-client-id` | `stub` |
| `KEYCLOAK_PLUGIN_CLIENT_SECRET` | `keycloak-plugin-client-secret` | `stub` |

ESO will not become Ready until **every** key in `secrets.keys` exists in Vault.

After writing keys:

```bash
oc -n rhdh annotate externalsecret rhdh-secrets force-sync="$(date +%s)" --overwrite
```

**Vault plugin tab:** after `VAULT_ADDR` + `VAULT_TOKEN` sync, open a catalog Component with `vault.io/secrets-path: rhdh`. You will see **names** under `secrets/rhdh`, not values. It does not work until that token can LIST `secrets/metadata/rhdh`.

---

## 3. Other Helm changes so the chart only deploys the RHDH instance

Create `values-cluster.yaml`:

```yaml
# Operators already installed.
operator:
  enabled: false

# Do not create a CNPG Cluster. Use bundled Postgres OR an existing Secret.
database:
  cnpg:
    enabled: false
  external:
    enabled: false          # true if you already have a Postgres Secret
instance:
  replicas: 1
  database:
    enableLocalDb: true     # false if external.enabled is true

createNamespace: true
namespace: rhdh

secrets:
  mode: eso                 # requires ClusterSecretStore vault-secret-store
  eso:
    storeName: vault-secret-store
    storeKind: ClusterSecretStore
    vaultPrefix: rhdh       # must match Vault path prefix

app:
  title: Developer Hub
  organization: YourOrg
  clusterBaseDomain: apps.YOURCLUSTER.openshiftapps.com
  baseUrl: https://backstage-developer-hub-rhdh.apps.YOURCLUSTER.openshiftapps.com
  readingAllow:
    # copy the list from section 1, with your hosts

auth:
  environment: production
  signInPage:
    - microsoft
  microsoft:
    domainHint: yourtenant.onmicrosoft.com

catalog:
  ldap:
    enabled: false          # set true only if OpenLDAP (or corporate LDAP) is in-cluster
  demoKitchenSink:
    enabled: true           # optional: one entity that has every plugin annotation
  locations: []             # or point at YOUR golden-path raw GitHub URLs

plugins:
  kubernetes:
    clusterName: YOURCLUSTER
    url: https://kubernetes.default.svc
    skipTLSVerify: true
    serviceAccountToken: ""
    caData: ""
  jira:
    product: cloud
    authorization: "${JIRA_TOKEN}"
  dynatrace:
    apiTarget: https://xxxx.live.dynatrace.com/api/v2
  snyk:
    mocked: true            # until you have a real SNYK_TOKEN
  vault:
    secretEngine: secrets   # must match the KV mount name
    kvVersion: 2
```

What this chart will then create in `rhdh`:

- Backstage CR `developer-hub`
- ConfigMaps: app-config, dynamic-plugins, RBAC, branding
- ExternalSecret `rhdh-secrets`
- Route to the Hub
- Plugin packages: Kubernetes, Jenkins, Argo, Sonar, Snyk, Jira, Artifactory, Vault, ServiceNow, Kiali, Dynatrace, APIC, TechDocs, Tekton, notifications (all `enabled: true` in `values.yaml`)

What it will **not** create: RHDH operator, CNPG operator, Vault, ESO, Jenkins, Sonar, Kiali, GitOps.

Also required **outside** Helm:

1. `ClusterSecretStore` named `vault-secret-store` pointing at the same Vault.
2. Entra redirect URI = `{baseUrl}/api/auth/microsoft/handler/frame`.
3. Catalog tabs still need entity annotations (`jira/project-key`, `kiali.io/namespace`, `dynatrace.com/dynatrace-entity-id`, `vault.io/secrets-path`). The golden-path templates already stamp those.

Do not helm-install with `-f values-demo.yaml` on a new cluster: it hardcodes this lab’s Hub URL, Jira site, Dynatrace tenant, and Argo route.

---

## 4. Corporate HTTP proxy for SaaS calls

Use this when the cluster must reach ServiceNow, Jira, Dynatrace, Entra, GitHub, and the other SaaS hosts through an authenticated forward proxy. This lab uses in-cluster Squid (`charts/squid`). The Hub still adds the SaaS credential (`SERVICENOW_PASSWORD`, `JIRA_TOKEN`, `DYNATRACE_ACCESS_TOKEN`, and the rest). The proxy only opens the tunnel. Questions to ask, and the Basic-auth and TLS limits, are in [PROXY-AUTH.md](PROXY-AUTH.md).

`app.readingAllow` does not change the path. It only lists hostnames the Hub is willing to call. Keep those entries, including the ServiceNow host.

The ServiceNow plugin has no proxy field. A ServiceNow call uses the process `HTTP_PROXY` when that host is **absent** from `NO_PROXY`. This lab keeps `.service-now.com` on `NO_PROXY` until the Squid path (previously 502) is proven.

This does not cover Dev Spaces, the operators, or image pulls. Those follow the OpenShift cluster `Proxy` object, not the Hub setting below. Plugin-install init stays off the Hub proxy (`httpProxy.initContainer` empty) because registry CDNs will not match the Squid allow list.

### Check the cluster proxy first

```bash
oc get proxy cluster -o jsonpath='{.spec.httpsProxy}{"\n"}{.spec.noProxy}{"\n"}'
POD=$(oc -n rhdh get pod -l app.kubernetes.io/name=backstage -o jsonpath='{.items[0].metadata.name}')
oc -n rhdh exec "$POD" -c backstage-backend -- sh -c 'echo HTTPS_PROXY set: ${HTTPS_PROXY:+yes}; echo NO_PROXY=$NO_PROXY'
```

If OpenShift already injects `HTTPS_PROXY` into the pod, skip the in-cluster URL and only do the Node flag, `NO_PROXY`, and the CA steps.

### 1. Squid htpasswd and Hub proxy keys (this lab, `secrets.mode: external`)

Do not commit the URL or the hash. Percent-encode `@`, `:`, and `/` in the password. `HTTP_PROXY` and `HTTPS_PROXY` are the same `http://` URL. The proxy authenticates the `CONNECT`; ServiceNow still sees its own username and password inside TLS.

```bash
oc apply -f examples/squid-htpasswd.example.yaml   # after filling passwd: rhdh:<apr1 hash>
# add HTTP_PROXY, HTTPS_PROXY, NO_PROXY to Secret rhdh-secrets (see examples/rhdh-secrets.example.yaml)
```

`NO_PROXY` must include every in-cluster name the Hub dials (`rhdh-pg-rw`, `.svc`, the Kubernetes API at `172.30.0.1` / `kubernetes.default.svc` / `kubernetes.default.svc.cluster.local`, Jenkins, Sonar, Vault, LDAP, stubs, Kiali at `kiali.istio-system.svc`, and a leading-dot cluster apps domain). The Kubernetes plugin uses `KUBERNETES_SERVICE_HOST` (the Service cluster IP), which `.svc` does not match. Put `.service-now.com` on `NO_PROXY` until the Squid path is proven. Axios treats a `NO_PROXY` entry without a leading dot as an exact host, so `apps.<cluster>` does not bypass `kiali-istio-system.apps.<cluster>`.

### 2. Turn the chart flag on

`httpProxy.enabled` is true in `values-deploy.yaml` for this lab. `NODE_OPTIONS` is replaced, not appended, so the value is `--no-node-snapshot --use-env-proxy`.

On a cluster that uses Vault + External Secrets instead, store the three keys first, then set the flag:

```yaml
httpProxy:
  enabled: true
```

```bash
vault kv put secrets/rhdh/http-proxy  value='http://USER:PASSWORD@proxy.example.com:8080'
vault kv put secrets/rhdh/https-proxy value='http://USER:PASSWORD@proxy.example.com:8080'
vault kv put secrets/rhdh/no-proxy value='localhost,127.0.0.1,.svc,.svc.cluster.local,.cluster.local'
oc -n rhdh annotate externalsecret rhdh-secrets force-sync="$(date +%s)" --overwrite
```

Leave the flag false until the three keys exist. ExternalSecret stays NotReady if any Vault key is missing.

### 3. Proxy TLS inspection

If the proxy presents its own certificate, mount that CA and set `NODE_EXTRA_CA_CERTS` to the file. Do not rely on `NODE_TLS_REJECT_UNAUTHORIZED=0`. That is the lab setting in `instance.extraEnvs` and it hides a bad certificate.

### 4. Restart and check

ExternalSecret updates the Secret. The running process keeps the old environment until the pod is recreated.

```bash
oc -n rhdh rollout restart deploy/backstage-developer-hub
oc -n rhdh rollout status deploy/backstage-developer-hub
```

From the new pod, confirm the flag and that a SaaS call is no longer a direct dial. Do not print the proxy URL or the SaaS tokens.

```bash
POD=$(oc -n rhdh get pod -l app.kubernetes.io/name=backstage -o jsonpath='{.items[0].metadata.name}')
oc -n rhdh exec "$POD" -c backstage-backend -- node -e '
const { getGlobalDispatcher } = require("undici");
console.log("node", process.version);
console.log("NODE_OPTIONS", process.env.NODE_OPTIONS || "(unset)");
console.log("https_proxy_set", Boolean(process.env.HTTPS_PROXY));
console.log("no_proxy", process.env.NO_PROXY || "(unset)");
console.log("dispatcher", getGlobalDispatcher().constructor.name);
'
```

`dispatcher` should be `EnvHttpProxyAgent` when the flag and `HTTPS_PROXY` are both set. Then open the Jira and Dynatrace tabs on `plugin-kitchen-sink`. A proxy refusal shows up as a connection error in the backend log, not as a 401 from Jira. A 401 still means the SaaS token, not the corporate proxy.
