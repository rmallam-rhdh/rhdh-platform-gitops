# Dev Spaces Multicluster Redirector

Helm chart for the [Red Hat Multicluster Redirector](https://catalog.redhat.com/en/software/containers/devspaces/multicluster-redirector-rhel9/69a1b8d94d1e7c99baa33970)
(`registry.redhat.io/devspaces/multicluster-redirector-rhel9`) with an OpenShift OAuth Proxy sidecar.

Routes authenticated users to a Dev Spaces dashboard URL based on OpenShift group membership.
Upstream OpenShift manifests (no official Helm chart): [redhat-developer/devspaces-multicluster-redirector](https://github.com/redhat-developer/devspaces-multicluster-redirector/tree/main/openshift).

## What the chart creates (namespace-scoped, all named from `.Release.Name`)

Every resource and Secret name is derived automatically from `.Release.Name` (for example `helm upgrade --install devspacesmcr .` creates `devspacesmcr-*`), so you never have to hardcode resource/secret names in `values.yaml` or collide with an existing `devspaces` installation in the same namespace:

| Resource | Generated Name (`<release>` = `.Release.Name`) | Purpose |
|---|---|---|
| Deployment | `<release>` | Quarkus redirector (`/hello` HTTP probes) + oauth-proxy (`/oauth/healthz` HTTP probes) with `restricted-v2` securityContext and anti-affinity |
| PodDisruptionBudget | `<release>` | Keeps at least `pdb.minAvailable` (default `1`) pod available when `replicas > 1` |
| Service + Route (edge TLS) | `<release>` | Public entry (automatically mounts `<release>-tls` via `externalCertificate` when `venafi.enabled=true`) |
| ConfigMap | `<release>-group-mapping` | `group-mapping.json` at `/etc/config` |
| Session Secret / VaultStaticSecret / ExternalSecret | `<release>-session-secret` | oauth-proxy session cookie secret (`sessionSecret.mode`) |
| Venafi Credentials Secret / VaultStaticSecret / ExternalSecret | `<release>-venafi-credentials` | Venafi TPP credentials referenced by `<release>-issuer` (`venafi.credentialsSecret.mode`) |
| Issuer | `<release>-issuer` | Namespace-scoped `cert-manager.io/v1` Venafi TPP `Issuer` (`venafi.enabled`) |
| Certificate + TLS Secret | `<release>-cert` → `<release>-tls` | `cert-manager.io/v1` `Certificate` (Venafi `custom-fields`, cluster + GSLB SANs, X.509 `subject`) |
| Role + RoleBinding | `<release>-router-tls` | Grants `openshift-ingress/router` read/watch access on `<release>-tls` for automatic renewal reload |
| ServiceAccount | `<release>` | OAuth client + redirect URI / Route reference |
| NetworkPolicy | `<release>` | Ingress 8443 (optional) |

Cluster-scoped RBAC is **not** in the chart. Apply once as cluster-admin:

```bash
oc apply -f manifests/devspaces-multicluster-redirector/rbac.yaml
```

That grants TokenReviews / SubjectAccessReviews / OpenShift `users`+`groups` get/list to
`ServiceAccount/devspaces-multicluster-redirector` in `devspaces-redirector`. If you change
`namespace` or the release name/fullname, update the binding subject to match.

## Configure

Edit `values-deploy.yaml` (do not add another overlay file):

1. Configure `sessionSecret` for your Vault mount/path and `VaultAuth` reference (see [Session secret (Vault)](#session-secret-vault) below).
2. Set `groupMapping` keys to OpenShift `Group` names and values to target `CheCluster` dashboard URLs (see [Adding groups to redirect](#adding-groups-to-redirect) below).
3. After the Route exists, either keep `route.oauthRedirectReference: true` (default) or set `route.host` / `route.oauthCallbackUrl` and set `oauthRedirectReference: false`.
4. Ensure the cluster can pull `registry.redhat.io` (pull secret on the namespace or global pullers).

## Adding groups to redirect

Keep `groupMapping: {}` empty in `values.yaml` (Helm deep-merges maps across value files, so any default key in `values.yaml` would leak into every deployment). Define all group redirects in `values-deploy.yaml`:

```yaml
groupMapping:
  # 1) Route different OpenShift groups to different Dev Spaces clusters:
  cluster-a-devs: https://devspaces.apps.cluster-a.example.com
  cluster-b-devs: https://devspaces.apps.cluster-b.example.com

  # 2) Route multiple OpenShift groups to the same Dev Spaces cluster (OR logic):
  frontend-devs: https://devspaces.apps.cluster-a.example.com
  backend-devs: https://devspaces.apps.cluster-a.example.com

  # 3) Require membership in ALL listed groups (AND logic — comma-separated key):
  #    Quote keys with commas in YAML and omit spaces around commas.
  "payments-devs,pci-cleared": https://devspaces.apps.pci-cluster.example.com
```

### Rules & OpenShift group setup

* **Target URL validation:** Every value must be a valid `http://` or `https://` Dev Spaces dashboard URL (no whitespace); invalid URLs fail `helm template` / `helm lint` early.
* **Single group vs. multi-group keys:**
  * Separate keys act as **OR** rules (a user in `frontend-devs` **or** `backend-devs` redirects to `cluster-a`).
  * A comma-separated key (`"group1,group2"`) acts as an **AND** rule (upstream `GroupMappingService` requires the user to belong to **all** listed OpenShift groups).
* **Creating & populating OpenShift groups:**
  ```bash
  oc adm groups new cluster-a-devs
  oc adm groups add-users cluster-a-devs alice bob
  ```
* **Live updates:** Quarkus `GroupMappingService` re-reads `/etc/config/group-mapping.json` dynamically on every request. When `rolloutOnConfigChange: true` (default), the Deployment also carries a `checksum/config` annotation to roll pods cleanly on GitOps sync.

## Session secret (Vault)

In a multi-cluster setup (Primary + DR behind a GTM / load balancer), **both clusters must pull the same `session_secret` from HashiCorp Vault** so OAuth session cookies remain valid across endpoints and no secret material is stored in Git.

Seed the secret once in Vault (must be at least 16 bytes; 32 hex chars recommended):

```bash
vault kv put secrets/devspaces-redirector/session session_secret="$(openssl rand -hex 16)"
```

`sessionSecret.mode` supports four modes:

### 1. `vaultStaticSecret` *(Default — HashiCorp Vault Secrets Operator)*

Renders a `secrets.hashicorp.com/v1beta1` `VaultStaticSecret` that syncs `<mount>/<path>` into Kubernetes Secret `<fullname>-session-secret` (and automatically triggers a Deployment rollout restart via `rolloutRestartTargets` when rotated in Vault):

```yaml
sessionSecret:
  mode: vaultStaticSecret
  secretKey: session_secret          # Key expected inside the synced Kubernetes Secret
  vaultStaticSecret:
    type: kv-v2                      # kv-v2 or kv-v1
    mount: secrets                   # Vault KV mount path
    path: devspaces-redirector/session
    vaultAuthRef: default            # VaultAuth CR name (leave "" to use VSO operator default)
    vaultNamespace: ""               # Optional Vault Enterprise namespace (e.g. "admin/platform")
    refreshAfter: 1h
    hmacSecretData: true
    rolloutRestart: true
    overwrite: true
    transformation: {}               # Optional VSO SecretTransformation if renaming Vault keys
```

> If your Vault KV secret uses a property name other than `session_secret`, either set `sessionSecret.secretKey` to match that property name or map it using `sessionSecret.vaultStaticSecret.transformation`.

### 2. `eso` *(External Secrets Operator)*

Renders an `external-secrets.io/v1` `ExternalSecret` referencing a `ClusterSecretStore` / `SecretStore`:

```yaml
sessionSecret:
  mode: eso
  eso:
    storeName: vault-secret-store
    storeKind: ClusterSecretStore
    refreshInterval: 1h
    remoteKey: devspaces-redirector/session
    remoteProperty: session_secret
```

### 3. `external` *(Pre-existing Kubernetes Secret)*

Mounts an existing Kubernetes Secret without rendering `VaultStaticSecret`, `ExternalSecret`, or `Secret`:

```yaml
sessionSecret:
  mode: external
  existingSecret: my-custom-session-secret
```

### 4. `secret` *(Standalone / Lab Only — No Vault)*

Generates a Kubernetes `Secret` via Helm `lookup` (paired with `ignoreDifferences` on `/data/session_secret` + `RespectIgnoreDifferences=true` in `argocd/apps/devspaces-multicluster-redirector.yaml` so Argo CD offline rendering preserves the secret across syncs):

```yaml
sessionSecret:
  mode: secret
```

## TLS Issuer & Certificate (Venafi TPP + cert-manager + GSLB SAN)

When `venafi.enabled: true`, the chart automatically creates all PKI resources named after `.Release.Name` (zero manual secret/issuer/certificate names required in `values.yaml`):

1. **`<release>-venafi-credentials`** (`VaultStaticSecret`, `ExternalSecret`, or `Secret` via `venafi.credentialsSecret.mode`).
2. **`<release>-issuer`** (`templates/issuer.yaml` — `cert-manager.io/v1` `Issuer` pointing at `venafi.zone` and `venafi.tpp.url`).
3. **`<release>-cert` → `<release>-tls`** (`templates/certificate.yaml` — `cert-manager.io/v1` `Certificate` with `venafi.cert-manager.io/custom-fields`, `Application Name` defaulted to `<release>`, cluster `hostname` SAN, plus `gslbHostname` SAN whenever `environmentName != "edev"`).
4. **`<release>-router-tls` + `Route.spec.tls.externalCertificate`** (`venafi.attachToRoute: true` — allows `system:serviceaccount:openshift-ingress:router` to watch `<release>-tls` and hot-reload on renewal).

```yaml
environmentName: nprd

venafi:
  enabled: true
  hostname: devspaces-redirector.apps.dc1.example.com
  gslbHostname: devspaces-redirector.example.com
  zone: "VED\\Policy\\Certificates\\DevSpaces"
  tpp:
    url: https://tpp.example.com/vedsdk
  credentialsSecret:
    mode: vaultStaticSecret
    vaultStaticSecret:
      type: kv-v2
      mount: secrets
      path: venafi/tpp
      vaultAuthRef: default
  customFields:
    technicalOwner: "Platform Engineering"
  subject:
    countries:
      - US
    localities:
      - San Francisco
    organizationalUnits:
      - Platform Engineering
    organizations:
      - Acme Corp
    provinces:
      - California
```

## Deploy

1. Cluster-admin: apply `manifests/devspaces-multicluster-redirector/rbac.yaml` (and ensure the target namespace and `VaultAuth` / secret store exist).
2. Sync Argo Application `argocd/apps/devspaces-multicluster-redirector.yaml`, or Helm-install the chart into that namespace.

```bash
helm lint charts/devspaces-multicluster-redirector
./charts/devspaces-multicluster-redirector/tests/test-chart.sh
```
