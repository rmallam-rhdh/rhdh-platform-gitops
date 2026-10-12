# IDP platform GitOps

Deploy **Red Hat Developer Hub**, **OpenShift Service Mesh 3** (ambient), **Dev Spaces**, and **CloudNativePG** from this repo with Argo CD.

Nothing else is in here (no Jenkins, Vault, golden paths, or workshop docs).

| Application | Wave | Path | What it installs |
|---|---|---|---|
| `cnpg-operator` | 0 | `components/cnpg/base` | Certified CloudNativePG operator in `cnpg-system` |
| `openshift-service-mesh` | 1 | `components/service-mesh/overlays/lab` | OSSM 3 + Istio/CNI/ztunnel + Kiali (redhat-operators) |
| `openshift-devspaces` | 2 | `components/devspaces/overlays/production` | Dev Spaces operator + `CheCluster` |
| `developer-hub` | 3 | `charts/developer-hub` | RHDH operator, Backstage CR, **CNPG `Cluster` `rhdh-pg`** |

The Postgres **operator** is the CNPG app. The Postgres **cluster** for Hub is created by the Helm chart (`database.cnpg.enabled` in `values-deploy.yaml`).

## Prerequisites

- OpenShift 4.x with cluster-admin
- [OpenShift GitOps](https://docs.redhat.com/en/documentation/red_hat_openshift_gitops) installed (`openshift-gitops` namespace)
- Cluster can pull `redhat-operators` and `certified-operators`
- Edit `charts/developer-hub/values-deploy.yaml`:
  - `app.clusterBaseDomain` = your apps domain (the part after the Route host)
  - auth / LDAP / plugin URLs if you are not using guest

Do **not** commit real secrets. `values-deploy.yaml` uses `secrets.mode: placeholder` so Hub can start. Replace `rhdh-secrets` afterwards, or switch to `external` and apply `examples/rhdh-secrets.example.yaml`.

## Deploy

```bash
# 1. Confirm GitOps is up
oc -n openshift-gitops get deploy openshift-gitops-server

# 2. Point the Applications at this repo (already set to
#    https://github.com/rmallam/rhdh-platform-gitops main)

# 3. Create the four Applications via the app-of-apps
oc apply -f argocd/app-of-apps.yaml
```

Or apply them one by one:

```bash
oc apply -f argocd/apps/cnpg.yaml
oc apply -f argocd/apps/service-mesh.yaml
oc apply -f argocd/apps/devspaces.yaml
oc apply -f argocd/apps/developer-hub.yaml
```

Wait for operators before expecting Hub to be Ready:

```bash
oc -n cnpg-system get csv
oc get csv -n openshift-operators | grep -E 'servicemesh|kiali|rhdh|devspaces'
oc get istio,istiocni,ztunnel -A
oc -n rhdh get cluster,backstage,route
```

Hub URL is the Route `backstage-developer-hub` in `rhdh` (name may vary with the Helm release).

## Service Mesh overlay

`argocd/apps/service-mesh.yaml` uses **`overlays/lab`**: `redhat-operators`, anonymous Kiali, no Vault mesh CA. That matches a ROSA lab.

For a DC that uses a snapshot catalog and Vault-issued mesh CA, change the Application path to `components/service-mesh/overlays/production` and seed those secrets first.

## RHDH values you must change

| Key | File | Why |
|---|---|---|
| `app.clusterBaseDomain` | `values-deploy.yaml` | Hub `baseUrl` and the Route host |
| `auth.*` | `values-deploy.yaml` | Guest is on for a first login; turn it off for a bank |
| `catalog.ldap` | `values.yaml` / overlay | Off in `values-deploy.yaml` until you have LDAP |
| `permission.adminUsers` | `values.yaml` | Platform admins; do not put `rbac_admin` in the CSV |
| Plugin URLs / tokens | Secret `rhdh-secrets` | Never in Git |

## Layout

```
argocd/app-of-apps.yaml          bootstrap Application
argocd/apps/                     the four Applications
components/cnpg/base/            CNPG operator
components/service-mesh/         OSSM 3 (lab + production overlays)
components/devspaces/            Dev Spaces operator + CheCluster
charts/developer-hub/            RHDH Helm (operator, CR, plugins, CNPG Cluster)
examples/rhdh-secrets.example.yaml
```

## Test

```bash
./tests/test-repo.sh
```

Requires `helm` and `kustomize` or `oc` / `kubectl`.

## What this repo does not install

OpenShift GitOps itself, Vault, External Secrets, Jenkins, SonarQube, or golden-path templates. Those live in the larger `RHDH-SM-DevSpaces` / `RHDH` repos.
