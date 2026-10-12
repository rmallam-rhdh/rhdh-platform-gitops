# IDP platform GitOps

Helm charts that create **custom resources only**. Operators are assumed already installed.

| Chart | Argo app | Creates |
|---|---|---|
| `charts/cnpg` | `cnpg` | CloudNativePG `Cluster` `rhdh-pg` in `rhdh` |
| `charts/service-mesh` | `service-mesh` | `Istio`, `IstioCNI`, `ZTunnel`, `Kiali` |
| `charts/devspaces` | `devspaces` | `CheCluster` in `openshift-devspaces` |
| `charts/developer-hub` | `developer-hub` | RHDH `Backstage` CR, app-config, plugins, RBAC |

No `Subscription`, `OperatorGroup`, or catalog source is rendered.

## Already installed before you sync

- OpenShift GitOps (`openshift-gitops`)
- CloudNativePG operator (Certified, `cnpg-system`, AllNamespaces)
- Red Hat OpenShift Service Mesh 3 (Sail) and Kiali operators
- OpenShift Dev Spaces operator
- Red Hat Developer Hub operator

## Before first sync

Edit `charts/developer-hub/values-deploy.yaml`:

- `app.clusterBaseDomain` — your `*.apps` domain
- Guest is on so Hub can start. Turn it off and set Entra/LDAP for a real login.
- Secrets use placeholders (`secrets.mode: placeholder`). Replace Secret `rhdh-secrets` later, or set `secrets.mode: external` and apply `examples/rhdh-secrets.example.yaml`.

CNPG writes Secret `rhdh-pg-app`. The Hub chart reads it (`database.external`). The Cluster CR itself is only in `charts/cnpg`.

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
