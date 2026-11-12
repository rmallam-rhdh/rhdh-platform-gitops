# Dev Spaces Multicluster Redirector

Helm chart for the [Red Hat Multicluster Redirector](https://catalog.redhat.com/en/software/containers/devspaces/multicluster-redirector-rhel9/69a1b8d94d1e7c99baa33970)
(`registry.redhat.io/devspaces/multicluster-redirector-rhel9`) with an OpenShift OAuth Proxy sidecar.

Routes authenticated users to a Dev Spaces dashboard URL based on OpenShift group membership.
Upstream OpenShift manifests (no official Helm chart): [redhat-developer/devspaces-multicluster-redirector](https://github.com/redhat-developer/devspaces-multicluster-redirector/tree/main/openshift).

## What it creates

| Resource | Purpose |
|---|---|
| Namespace `devspaces-redirector` | Workload namespace (optional) |
| Deployment | Quarkus redirector + oauth-proxy |
| Service + Route (edge TLS) | Public entry |
| ConfigMap | `group-mapping.json` at `/etc/config` |
| Secret | oauth-proxy session cookie |
| ServiceAccount | OAuth client + redirect URI / Route reference |
| ClusterRole / Binding | groups, users, tokenreviews, SAR |
| NetworkPolicy | Ingress 8443 (optional) |

## Configure

Edit `values-deploy.yaml` (do not add another overlay file):

1. Set `groupMapping` keys to OpenShift Group names and values to CheCluster dashboard URLs.
2. After the Route exists, either keep `route.oauthRedirectReference: true` (default) or set `route.host` / `route.oauthCallbackUrl` and set `oauthRedirectReference: false`.
3. Ensure the cluster can pull `registry.redhat.io` (pull secret on the namespace or global pullers).

Comma-separated group keys require membership in **all** listed groups (upstream AND logic).

## Deploy

Argo Application: `argocd/apps/devspaces-multicluster-redirector.yaml`.

```bash
helm lint charts/devspaces-multicluster-redirector
./charts/devspaces-multicluster-redirector/tests/test-chart.sh
```

## Session secret

Default `sessionSecret.create: true` uses Helm `lookup` so upgrades keep the existing cookie. Set `create: false` and `existingSecret` when Vault/ESO owns the Secret (key must be `session_secret`).
