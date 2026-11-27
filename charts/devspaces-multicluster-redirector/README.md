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
| Session Secret | `<release>-session-secret` | Auto-generated random 32-character OAuth cookie encryption secret (`lookup` + `helm.sh/resource-policy: keep` — zero secret config in Git) |
| Issuer | `<release>-issuer` | Namespace-scoped `cert-manager.io/v1` Venafi TPP `Issuer` (`venafi.enabled`, referencing `<release>-venafi-credentials`) |
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
the namespace or release name, update the binding subject to match.

## Adding groups to redirect

Define group redirects in `values-deploy.yaml` using `datacenters` (or flat `groupMapping`):

```yaml
datacenters:
  dc1:
    url: https://devspaces.apps.dc1.example.com
    requiredGroup: ""
    groups:
      - corp_nprd_devspaces_admin
      - corp_nprd_payments_devs
  dc2:
    url: https://devspaces.apps.dc2.example.com
    requiredGroup: ""
    groups:
      - corp_nprd_lending_devs
```

## Session secret (Automatic Random 32-Character Secret)

`templates/secret-session.yaml` automatically generates a random 32-character alphanumeric `session_secret` in `<release>-session-secret` with **zero secret values or Vault/ESO boilerplate in `values.yaml`**:
* On `helm upgrade --install`, Helm `lookup` reads any existing `<release>-session-secret` in the namespace and preserves its `session_secret` (with `helm.sh/resource-policy: keep`).
* On **Argo CD** (where `helm template` runs offline), `argocd/apps/devspaces-multicluster-redirector.yaml` configures `ignoreDifferences` on `/data/session_secret` + `RespectIgnoreDifferences=true` so Argo CD preserves the generated value across syncs.

## TLS Issuer & Certificate (Venafi TPP + cert-manager + GSLB SAN)

When `venafi.enabled: true`, the chart automatically creates PKI resources named after `.Release.Name`:

1. **`<release>-issuer`** (`templates/issuer.yaml` — `cert-manager.io/v1` `Issuer` pointing at `venafi.zone`, `venafi.tpp.url`, and `credentialsRef.name: <release>-venafi-credentials`).
2. **`<release>-cert` → `<release>-tls`** (`templates/certificate.yaml` — `cert-manager.io/v1` `Certificate` with `venafi.cert-manager.io/custom-fields`, `Application Name` defaulted to `<release>`, cluster `hostname` SAN, plus `gslbHostname` SAN whenever `environmentName != "edev"`).
3. **`<release>-router-tls` + `Route.spec.tls.externalCertificate`** (`venafi.attachToRoute: true` — allows `system:serviceaccount:openshift-ingress:router` to watch `<release>-tls` and hot-reload on renewal).

```yaml
environmentName: nprd

venafi:
  enabled: true
  hostname: devspaces-redirector.apps.dc1.example.com
  gslbHostname: devspaces-redirector.example.com
  zone: "VED\\Policy\\Certificates\\DevSpaces"
  tpp:
    url: https://tpp.example.com/vedsdk
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

## Enterprise OpenShift Group List Tuning & Netty 4.2 Workaround

In enterprise OpenShift clusters synced with Active Directory (thousands of OpenShift `Group` objects), `GET /apis/user.openshift.io/v1/groups` returns a large multi-megabyte payload. In addition, `multicluster-redirector-rhel9:3.31` pairs Quarkus `3.39.5` with Netty `4.2.18` on OpenJDK 17 (`quarkusio/quarkus#53309`), which throws `CleanerJava9.INVOKE_CLEANER is null` on direct-buffer cleanup unless `DirectCleaner` is unlocked.

`templates/deployment.yaml` sets the following environment variables on the **`redirector` Java container** (not `oauth-proxy`), configurable under `kubernetesClient` in `values.yaml`:

```yaml
kubernetesClient:
  requestTimeoutMs: 60000
  connectionTimeoutMs: 30000
  javaToolOptions: "--add-opens=java.base/java.nio=ALL-UNNAMED -Dio.netty.tryReflectionSetAccessible=true -Dio.netty.noPreferDirect=true -Dio.netty.maxDirectMemory=268435456"
```

## Deploy

```bash
helm lint charts/devspaces-multicluster-redirector
./charts/devspaces-multicluster-redirector/tests/test-chart.sh
```
