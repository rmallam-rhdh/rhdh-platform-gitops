# Dev Spaces Multicluster Redirector

Helm chart for the [Red Hat Multicluster Redirector](https://catalog.redhat.com/en/software/containers/devspaces/multicluster-redirector-rhel9/69a1b8d94d1e7c99baa33970)
(`registry.redhat.io/devspaces/multicluster-redirector-rhel9`) with an OpenShift OAuth Proxy sidecar.

Routes authenticated users to a Dev Spaces dashboard URL based on OpenShift group membership.
Upstream OpenShift manifests (no official Helm chart): [redhat-developer/devspaces-multicluster-redirector](https://github.com/redhat-developer/devspaces-multicluster-redirector/tree/main/openshift).

## What the chart creates (namespace-scoped)

| Resource | Purpose |
|---|---|
| Deployment | Quarkus redirector (`/hello` HTTP probes) + oauth-proxy (`/oauth/healthz` HTTP probes) with `restricted-v2` securityContext and anti-affinity |
| PodDisruptionBudget | Keeps at least `pdb.minAvailable` (default `1`) pod available when `replicas > 1` |
| Service + Route (edge TLS) | Public entry |
| ConfigMap | `group-mapping.json` at `/etc/config` |
| Secret | oauth-proxy session cookie |
| ServiceAccount | OAuth client + redirect URI / Route reference |
| NetworkPolicy | Ingress 8443 (optional) |

Cluster-scoped RBAC is **not** in the chart. Apply once as cluster-admin:

```bash
oc apply -f manifests/devspaces-multicluster-redirector/rbac.yaml
```

That grants TokenReviews / SubjectAccessReviews / OpenShift `users`+`groups` get/list to
`ServiceAccount/devspaces-multicluster-redirector` in `devspaces-redirector`. If you change
`namespace` or the release name/fullname, update the binding subject to match.

## Configure

Edit `values-deploy.yaml` (do not add another overlay file):

1. Set `groupMapping` keys to OpenShift Group names and values to CheCluster dashboard URLs.
2. After the Route exists, either keep `route.oauthRedirectReference: true` (default) or set `route.host` / `route.oauthCallbackUrl` and set `oauthRedirectReference: false`.
3. Ensure the cluster can pull `registry.redhat.io` (pull secret on the namespace or global pullers).

Comma-separated group keys require membership in **all** listed groups (upstream AND logic).

## Deploy

1. Cluster-admin: apply `manifests/devspaces-multicluster-redirector/rbac.yaml` (and ensure the target namespace exists).
2. Sync Argo Application `argocd/apps/devspaces-multicluster-redirector.yaml`, or Helm-install the chart into that namespace.

```bash
helm lint charts/devspaces-multicluster-redirector
./charts/devspaces-multicluster-redirector/tests/test-chart.sh
```

## Session secret

Default `sessionSecret.create: true` uses Helm `lookup` for standalone Helm upgrades and `ignoreDifferences` (`/data/session_secret` + `RespectIgnoreDifferences=true`) in `argocd/apps/devspaces-multicluster-redirector.yaml` so Argo CD offline rendering keeps the existing cookie stable across syncs. Set `create: false` and `existingSecret` when Vault/ESO owns the Secret (key must be `session_secret`).
