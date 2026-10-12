# IDP platform GitOps

Helm charts that create **custom resources only**. Operators are assumed already installed.

| Chart | Argo app | Creates |
|---|---|---|
| `charts/cnpg` | `cnpg` | CloudNativePG `Cluster` `rhdh-pg` in `rhdh` |
| `charts/service-mesh` | `service-mesh` | `Istio`, `IstioCNI`, `ZTunnel`, `Kiali` |
| `charts/devspaces` | `devspaces` | `CheCluster` in `openshift-devspaces` (Route labels for the existing shared ingress) |
| `charts/developer-hub` | `developer-hub` | RHDH `Backstage` CR, app-config, plugins, RBAC |

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

## Dev Spaces and the existing shared ingress

The chart does not create an IngressController. It only labels the Dev Spaces Routes (`networking.labels`) so the shared ingress you already have can select them. Set those labels to that controller’s `spec.routeSelector.matchLabels`, and set `networking.domain` to its `spec.domain`. Leave `domain` empty to stay on the cluster default apps domain.

The CheCluster also sets enterprise workspace defaults: per-user PVC, one running workspace, 30 minute idle, nested container runtime off, image builds on the `container-build` SCC, metrics on, and NetworkPolicy for the Dev Spaces and workspace namespaces.

## Deploy

```bash
oc apply -f argocd/app-of-apps.yaml
```

Or one chart at a time:

```bash
oc apply -f argocd/apps/cnpg.yaml
oc apply -f argocd/apps/service-mesh.yaml
oc apply -f argocd/apps/devspaces.yaml
oc apply -f argocd/apps/developer-hub.yaml
```

Check:

```bash
oc -n rhdh get cluster,backstage,route
oc get istio,istiocni,ztunnel -A
oc -n istio-system get kiali
oc -n openshift-devspaces get checluster
```

## Layout

```
argocd/app-of-apps.yaml
argocd/apps/                 four Helm Applications
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
