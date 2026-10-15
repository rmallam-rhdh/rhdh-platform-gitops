# IDP platform GitOps

Helm charts that create **custom resources only**. Operators are assumed already installed.

| Chart | Argo app | Creates |
|---|---|---|
| `charts/cnpg` | `cnpg` | CloudNativePG `Cluster` `rhdh-pg` in `rhdh` (3 instances) |
| `charts/cnpg` (`values-dr.yaml`) | `cnpg-dr` | CloudNativePG `Cluster` `rhdh-pg-dr` in `rhdh-dr` (3 instances, not used by the Hub) |
| `charts/service-mesh` | `service-mesh` | `Istio`, `IstioCNI`, `ZTunnel`, `Kiali` |
| `charts/devspaces` | `devspaces` | `CheCluster` in `openshift-devspaces` (Route labels for the existing shared ingress) |
| `charts/developer-hub` | `developer-hub` | RHDH `Backstage` CR, app-config, plugins, RBAC |
| `charts/squid` | `squid` | Authenticated Squid in `squid`. The Hub does not use it until `httpProxy.enabled` is true |

No `Subscription`, `OperatorGroup`, or catalog source is rendered.

## Already installed before you sync

Operators and lab tools are **not** in this repo. Install them first, then sync this repo.

From [rmallam/RHDH](https://github.com/rmallam/RHDH) (or OperatorHub for the ones that repo does not subscribe):

- OpenShift GitOps
- CloudNativePG operator (`components/cnpg`)
- External Secrets, plus ClusterSecretStore `vault-secret-store`
- Red Hat OpenShift Service Mesh 3 (Sail) and Kiali operators
- OpenShift Dev Spaces operator
- Red Hat Developer Hub operator

Tools, also from that repo, so the Hub can reach them at the in-cluster URLs already in `values-demo.yaml`:

- `ldap`, `jenkins`, `sonarqube`, `vault`, `saas-stubs`

Do not also sync an Application that creates `Istio`, `CheCluster`, `Backstage`, or the Postgres `Cluster`. Those four custom resources come from this repo.

## Before first sync

Edit `charts/developer-hub/values-deploy.yaml` and set `app.clusterBaseDomain` to this cluster’s `*.apps` domain. The Hub URL, the OpenShift GitOps URL, and the Dev Spaces links inside the golden-path templates are derived from that value.

`values-demo.yaml` is the lab shape: guest and Entra (`mallamrakeshgmail.onmicrosoft.com`), LDAP, the kitchen-sink catalog, and the Node.js and Quarkus templates mounted from this chart. Secrets stay in Vault (`secrets.mode: eso`). Seed the same Vault paths the ExternalSecret reads. On the Entra app `rhdh-login`, set the Web redirect to `https://backstage-developer-hub-rhdh.<clusterBaseDomain>/api/auth/microsoft/handler/frame`.

CNPG writes Secret `rhdh-pg-app`. The Hub chart reads it. The Cluster CR itself is only in `charts/cnpg`.

The Node.js and Quarkus Template entities are registered from ConfigMap `rhdh-golden-path`. Their skeletons are still fetched from `rmallam/RHDH` when someone runs the template.

To send Hub calls to Jira, Dynatrace, Entra, and GitHub through a corporate HTTP proxy, set `httpProxy.enabled: true` after the Vault keys exist. The flag is off by default. Steps are in [Corporate HTTP proxy for SaaS calls](charts/developer-hub/DEPLOY-RHDH-ONLY.md#4-corporate-http-proxy-for-saas-calls). What to ask the customer, and what we can answer about Basic auth and TLS, is in [PROXY-AUTH.md](charts/developer-hub/PROXY-AUTH.md).

## Dev Spaces ingress shard

This chart does not create an IngressController. The shard is `tools/ingress-shard` in `rmallam/RHDH`: an IngressController named `devspaces` whose `routeSelector` is `ingress.openshift.io/shard: devspaces`, plus a selector on the default controller so unlabeled routes stay there. `charts/devspaces/values-deploy.yaml` sets the same label and sets `networking.domain` to that controller’s `spec.domain`. Dev Spaces publishes `https://devspaces.<domain>` on the shard load balancer.

The CheCluster also sets enterprise workspace defaults: per-user PVC, one running workspace, 30 minute idle, nested container runtime off, image builds on the `container-build` SCC, metrics on, and NetworkPolicy for the Dev Spaces and workspace namespaces.

## Deploy

The OpenShift GitOps controller cannot create these CRs until it is cluster-admin. Apply that binding once, then the app-of-apps:

```bash
oc apply -f argocd/gitops-controller-admin.yaml
oc apply -f argocd/app-of-apps.yaml
```

Or one chart at a time:

```bash
oc apply -f argocd/apps/cnpg.yaml
oc apply -f argocd/apps/cnpg-dr.yaml
oc apply -f argocd/apps/service-mesh.yaml
oc apply -f argocd/apps/devspaces.yaml
oc apply -f argocd/apps/developer-hub.yaml
oc apply -f argocd/apps/squid.yaml
```

Check:

```bash
oc -n rhdh get cluster,backstage,route
oc get istio,istiocni,ztunnel -A
oc -n istio-system get kiali
oc -n openshift-devspaces get checluster
```

## Runbooks

The runbooks for these charts live in [rmallam/RHDH](https://github.com/rmallam/RHDH/tree/main/docs):

| Chart | Runbook |
|---|---|
| `charts/service-mesh` | [service-mesh-ambient](https://github.com/rmallam/RHDH/tree/main/docs/service-mesh-ambient) — enrolment labels, and what is not proven yet |
| `charts/devspaces` | [devspaces](https://github.com/rmallam/RHDH/tree/main/docs/devspaces) — `CheCluster` settings and the ingress shard |
| `charts/cnpg` | [rhdh-cnpg](https://github.com/rmallam/RHDH/tree/main/docs/rhdh-cnpg) — says why the Postgres image is not pinned yet and what to pin; [rhdh-database](https://github.com/rmallam/RHDH/tree/main/docs/rhdh-database) — what the Hub stores, schema by schema |
| `charts/developer-hub` | [rhdh-plugins](https://github.com/rmallam/RHDH/tree/main/docs/rhdh-plugins), [rhdh-entra-ldap](https://github.com/rmallam/RHDH/tree/main/docs/rhdh-entra-ldap), [rhdh-vault-eso](https://github.com/rmallam/RHDH/tree/main/docs/rhdh-vault-eso) |
| whole cluster | [lab-state](https://github.com/rmallam/RHDH/tree/main/docs/lab-state) — installed versions, what is deployed, lab-only settings |

`charts/developer-hub/values-deploy.yaml` sets `mesh.ambient: false`, so namespace `rhdh` is not in the mesh. The chart default is still `mesh.ambient: true`. Turning that on sends the Hub and Postgres through ztunnel, and kubelet probes to CloudNativePG port 8000 time out. Both charts still render `Namespace/rhdh`, so their labels can overwrite each other.

## Layout

```
argocd/app-of-apps.yaml
argocd/apps/                 Helm Applications
charts/cnpg/
charts/service-mesh/
charts/devspaces/
charts/developer-hub/
examples/rhdh-secrets.example.yaml
```

## Test

```bash
./tests/test-repo.sh
```
