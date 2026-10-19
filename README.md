# IDP platform GitOps

Helm charts that create **custom resources only**. Operators are assumed already installed.

| Chart | Argo app | Creates |
|---|---|---|
| `charts/cnpg` | `cnpg` | CloudNativePG `Cluster` `rhdh-pg` in `rhdh` (3 instances) |
| `charts/cnpg` (`values-dr.yaml`) | `cnpg-dr` | CloudNativePG `Cluster` `rhdh-pg-dr` in `rhdh-dr` (3 instances, not used by the Hub) |
| `charts/service-mesh` | `service-mesh` | `Istio`, `IstioCNI`, `ZTunnel`, `Kiali` |
| `charts/devspaces` | `devspaces` | `CheCluster` in `openshift-devspaces` (Route labels for the existing shared ingress) |
| `charts/developer-hub` | `developer-hub` | RHDH `Backstage` CR, app-config, plugins, RBAC |
| `charts/squid` | `squid` | Authenticated Squid. Hub uses it when `httpProxy.enabled` is true |

No `Subscription`, `OperatorGroup`, or catalog source is rendered.

## Already installed before you sync

Operators and lab tools are **not** in this repo. Install them first, then sync this repo.

From [rmallam-rhdh/RHDH-SM-DevSpaces](https://github.com/rmallam-rhdh/RHDH-SM-DevSpaces) branch `main` (apply `bootstrap/root-app.yaml` first):

- OpenShift GitOps (and the controller cluster-admin binding)
- CloudNativePG operator
- Red Hat OpenShift Service Mesh 3 (Sail) and Kiali operators
- OpenShift Dev Spaces operator
- Red Hat Developer Hub operator
- `ldap`, `jenkins`, `sonarqube`, `vault`, `saas-stubs`

External Secrets is not required when `secrets.mode: external`.

Do not also sync an Application that creates `Istio`, `CheCluster`, `Backstage`, or the Postgres `Cluster`. Those four custom resources come from this repo.

## Before first sync

Edit `charts/developer-hub/values-deploy.yaml` (do not add another overlay file) and set `app.clusterBaseDomain` to this cluster’s `*.apps` domain. The Hub URL, the OpenShift GitOps URL, and the Dev Spaces links inside the golden-path templates are derived from that value. The same file is where you flip `secrets.mode` (`external` when Secret `rhdh-secrets` already exists, `eso` when Vault + External Secrets should own it) and `httpProxy.enabled`.

`values-demo.yaml` is the lab shape: guest and Entra (`mallamrakeshgmail.onmicrosoft.com`), LDAP, the kitchen-sink catalog, and the Node.js and Quarkus templates mounted from this chart. On the Entra app `rhdh-login`, set the Web redirect to `https://backstage-developer-hub-rhdh.<clusterBaseDomain>/api/auth/microsoft/handler/frame`.

CNPG writes Secret `rhdh-pg-app`. The Hub chart reads it. The Cluster CR itself is only in `charts/cnpg`.

Scaffolder Template entities are registered from ConfigMap `rhdh-golden-path` in this chart. Their skeletons are fetched from `rmallam/RHDH-SM-DevSpaces` branch `main`.

Hub egress (ServiceNow, Jira, Dynatrace, Entra, GitHub) goes through in-cluster Squid when `httpProxy.enabled` is true in `values-deploy.yaml`. Secret `rhdh-secrets` must already have `HTTP_PROXY`, `HTTPS_PROXY`, and `NO_PROXY`. Leave `*.service-now.com` off `NO_PROXY`. Apply Secret `squid-htpasswd` from [examples/squid-htpasswd.example.yaml](examples/squid-htpasswd.example.yaml) before the Squid Application is Ready. Steps are in [Corporate HTTP proxy for SaaS calls](charts/developer-hub/DEPLOY-RHDH-ONLY.md#4-corporate-http-proxy-for-saas-calls). What to ask the customer, and what we can answer about Basic auth and TLS, is in [PROXY-AUTH.md](charts/developer-hub/PROXY-AUTH.md).

## Dev Spaces ingress

This chart does not create an IngressController. Default is the cluster `*.apps` domain with no shard label. If a cluster has a Dev Spaces shard, set `networking.domain` and `networking.labels` in `charts/devspaces/values-deploy.yaml` — do not add a second overlay file.

The CheCluster also sets enterprise workspace defaults: per-user PVC, one running workspace, 30 minute idle, nested container runtime off, image builds on the `container-build` SCC, metrics on, and NetworkPolicy for the Dev Spaces and workspace namespaces.

## Deploy

Day-1 (`RHDH-SM-DevSpaces` `bootstrap/root-app.yaml`) already binds the GitOps controller to cluster-admin. After operators are Ready and Secret `rhdh-secrets` exists:

```bash
oc apply -f argocd/app-of-apps.yaml
```

Check:

```bash
oc -n rhdh get cluster,backstage,route
oc get istio,istiocni,ztunnel -A
oc -n istio-system get kiali
oc -n openshift-devspaces get checluster
oc -n squid get deploy,svc
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

Hub and Postgres stay off the mesh (`mesh.ambient: false` in the Hub chart; CNPG stamps `istio.io/dataplane-mode: none` on `Namespace/rhdh`). Turning ambient on sends them through ztunnel, and kubelet probes to CloudNativePG port 8000 time out. `NO_PROXY` on Secret `rhdh-secrets` must include the Kubernetes API (`172.30.0.1`, `kubernetes.default.svc`, `kubernetes.default.svc.cluster.local`) so the Kubernetes plugin does not go via Squid.

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
