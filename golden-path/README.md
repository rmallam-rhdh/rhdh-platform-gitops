# Golden Path Software Templates — Multi-Cluster & Multi-Namespace Kubernetes Discovery

All Golden Path templates in this repository (`nodejs`, `springboot`, `quarkus`, `nodejs-website`, `node-udi`, and `plugin-kitchen-sink`) use **cluster-wide label-selector discovery** so that a **single shared `catalog-info.yaml`** works across multiple OpenShift clusters and differently named environment namespaces (`EDEV`, `NPRD`, `PROD`).

---

## 1. How Catalog & Workload Annotations Work Across Clusters and Namespaces

### In `catalog-info.yaml`
All Golden Path templates set **only** `backstage.io/kubernetes-id` and intentionally **omit** `backstage.io/kubernetes-namespace`:

```yaml
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: my-service
  annotations:
    # Matches the backstage.io/kubernetes-id label on Kubernetes resources across all clusters & namespaces.
    # DO NOT set backstage.io/kubernetes-namespace when namespace names differ across environments/clusters.
    backstage.io/kubernetes-id: my-service
```

> **Why omit `backstage.io/kubernetes-namespace`?**
> In `@backstage/plugin-kubernetes-backend` (`KubernetesFanOutHandler`), `backstage.io/kubernetes-namespace` only accepts a **single string** and queries that exact same namespace path (`/namespaces/<ns>/...`) on every configured cluster.
> When `backstage.io/kubernetes-namespace` is **omitted**, RHDH queries cluster-wide using `?labelSelector=backstage.io/kubernetes-id=<app-name>` across every cluster in `kubernetes.clusterLocatorMethods`, automatically discovering the application's pods, deployments, services, and routes even when the namespace is named `team-payments-edev` in EDEV, `team-payments-nonprod` in NPRD, and `team-payments-prod` in PROD.

### In Application Helm Charts / Kustomize Manifests
Every Golden Path Helm chart (`_helpers.tpl`) and Kustomize base stamps the matching `backstage.io/kubernetes-id` label on all Kubernetes objects and Pod templates:

```yaml
metadata:
  labels:
    app.kubernetes.io/name: my-service
    backstage.io/kubernetes-id: my-service
```

---

## 2. Required ServiceAccount Permissions on Target Clusters

Because RHDH queries resources across namespaces using a label selector (`?labelSelector=backstage.io/kubernetes-id=<app-name>`), the ServiceAccount used by RHDH on each target OpenShift cluster requires a **cluster-scoped read-only `ClusterRole` and `ClusterRoleBinding`** (it does **not** require `cluster-admin`).

### Option A: Using the Built-In OpenShift `cluster-reader` Role (Quickest for Remote Clusters)
On each target OpenShift cluster, create a dedicated read-only ServiceAccount and bind it to OpenShift's built-in `cluster-reader` `ClusterRole`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: rhdh-kubernetes-reader
  namespace: rhdh # or default on remote clusters
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: rhdh-kubernetes-reader-binding
subjects:
  - kind: ServiceAccount
    name: rhdh-kubernetes-reader
    namespace: rhdh
roleRef:
  kind: ClusterRole
  name: cluster-reader
  apiGroup: rbac.authorization.k8s.io
```

### Option B: Least-Privilege Custom `ClusterRole` (`rhdh-kubernetes-reader`)
If your security team requires a least-privilege `ClusterRole` scoped strictly to the resource types queried by the RHDH Kubernetes, Topology, Tekton, Argo CD, and Service Mesh plugins (without granting access to `Secrets`), use the `rhdh-kubernetes-reader` `ClusterRole` deployed by `charts/developer-hub/templates/rbac-k8s.yaml`:

| API Group | Resources | Verbs | Why RHDH Needs It |
| :--- | :--- | :--- | :--- |
| `""` (core) | `pods`, `services`, `configmaps`, `namespaces`, `nodes`, `events`, `resourcequotas`, `limitranges`, `serviceaccounts`, `persistentvolumeclaims` | `get`, `list`, `watch` | Core Kubernetes & Topology workload status, pod health, and storage visibility |
| `""` (core) | `pods/log` | `get` | Viewing container logs from the RHDH Kubernetes/Topology UI |
| `metrics.k8s.io` | `pods`, `nodes` | `get`, `list`, `watch` | Pod CPU and Memory usage bars in the RHDH Kubernetes tab |
| `apps` | `deployments`, `replicasets`, `statefulsets`, `daemonsets` | `get`, `list`, `watch` | Deployment rollout state, replica counts, and Topology graph nodes |
| `batch` | `jobs`, `cronjobs` | `get`, `list`, `watch` | Batch Job and CronJob execution status |
| `autoscaling` | `horizontalpodautoscalers` | `get`, `list`, `watch` | HPA scaling targets and current replica metrics |
| `networking.k8s.io` | `ingresses`, `networkpolicies` | `get`, `list`, `watch` | Ingress and NetworkPolicy visibility |
| `route.openshift.io` | `routes` | `get`, `list`, `watch` | OpenShift Route external URL links in Topology & Kubernetes tabs |
| `tekton.dev` | `pipelineruns`, `taskruns`, `pipelines`, `tasks` | `get`, `list`, `watch` | Tekton pipeline execution visualization |
| `argoproj.io` | `applications`, `appprojects`, `applicationsets` | `get`, `list`, `watch` | Argo CD custom resource status |
| `sailoperator.io` | `istios`, `istiocnis`, `ztunnels`, `istiorevisions` | `get`, `list`, `watch` | OpenShift Service Mesh 3 control plane & ambient mesh status |
| `networking.istio.io`, `security.istio.io` | `virtualservices`, `destinationrules`, `gateways`, `peerauthentications`, `authorizationpolicies`, `sidecars` | `get`, `list`, `watch` | Istio traffic routing and mTLS policy visibility |
| `gateway.networking.k8s.io` | `gateways`, `httproutes` | `get`, `list`, `watch` | Kubernetes Gateway API & Ambient Mesh waypoint proxies |

#### Full Least-Privilege `ClusterRole` + `ClusterRoleBinding` YAML:
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: rhdh-kubernetes-reader
rules:
  - apiGroups: [""]
    resources: [pods, services, configmaps, namespaces, nodes, events, resourcequotas, limitranges, serviceaccounts, persistentvolumeclaims]
    verbs: [get, list, watch]
  - apiGroups: [""]
    resources: [pods/log]
    verbs: [get]
  - apiGroups: [metrics.k8s.io]
    resources: [pods, nodes]
    verbs: [get, list, watch]
  - apiGroups: [apps]
    resources: [deployments, replicasets, statefulsets, daemonsets]
    verbs: [get, list, watch]
  - apiGroups: [batch]
    resources: [jobs, cronjobs]
    verbs: [get, list, watch]
  - apiGroups: [autoscaling]
    resources: [horizontalpodautoscalers]
    verbs: [get, list, watch]
  - apiGroups: [networking.k8s.io]
    resources: [ingresses, networkpolicies]
    verbs: [get, list, watch]
  - apiGroups: [route.openshift.io]
    resources: [routes]
    verbs: [get, list, watch]
  - apiGroups: [tekton.dev]
    resources: [pipelineruns, taskruns, pipelines, tasks]
    verbs: [get, list, watch]
  - apiGroups: [argoproj.io]
    resources: [applications, appprojects, applicationsets]
    verbs: [get, list, watch]
  - apiGroups: [sailoperator.io]
    resources: [istios, istiocnis, ztunnels, istiorevisions]
    verbs: [get, list, watch]
  - apiGroups: [networking.istio.io, security.istio.io]
    resources: [virtualservices, destinationrules, gateways, peerauthentications, authorizationpolicies, sidecars]
    verbs: [get, list, watch]
  - apiGroups: [gateway.networking.k8s.io]
    resources: [gateways, httproutes]
    verbs: [get, list, watch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: rhdh-kubernetes-reader-binding
subjects:
  - kind: ServiceAccount
    name: default # or rhdh-kubernetes-reader
    namespace: rhdh
roleRef:
  kind: ClusterRole
  name: rhdh-kubernetes-reader
  apiGroup: rbac.authorization.k8s.io
```

---

## 3. Required RHDH RBAC Permissions (`rbac-policy.csv`)

In addition to the Kubernetes ServiceAccount `ClusterRole`, RHDH's internal RBAC (`permission.enabled: true`) requires two permissions granted to developer roles in `rbac-policy.csv` so logged-in RHDH users can view the Kubernetes & Topology tabs:

```csv
p, role:default/developer, kubernetes.clusters.read, read, allow
p, role:default/developer, kubernetes.resources.read, read, allow
p, role:default/developer, kubernetes.proxy, use, allow
```
