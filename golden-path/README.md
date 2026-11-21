# RHDH Enterprise Golden Path Templates & Skeletons (`rhdh-platform-gitops`)

All Golden Path Software Templates (`golden-path/templates/`) and application skeletons (`golden-path/skeletons/`) are **100% self-contained in this repository (`rhdh-platform-gitops`)**, with zero dependency on external or locked repositories.

---

## 1. Self-Contained Golden Path Architecture

| Directory / Chart | Purpose |
| :--- | :--- |
| `golden-path/templates/template-quarkus-golden-path.yaml` | End-to-end **Quarkus 3 / Java 21** Golden Path (`APPID`, `groupName`, Command Centre 6-tab + Overview Bento grid, Jenkins + SonarQube + Ambient Mesh Helm chart, and GitOps Dev Spaces namespace check/provisioning) |
| `golden-path/templates/template-nodejs-golden-path.yaml` | End-to-end **Node.js 20** Golden Path (`APPID`, `groupName`, Command Centre 6-tab + Overview Bento grid, Jenkins + SonarQube + Ambient Mesh Helm chart, and GitOps Dev Spaces namespace check/provisioning) |
| `golden-path/skeletons/skeleton-quarkus-golden-path/` | Self-contained Quarkus 3 / Java 21 source code, `pom.xml`, JUnit 5 tests, `openapi.yaml`, `Jenkinsfile`, `sonar-project.properties`, `devfile.yaml`, Ambient Mesh Helm `/chart`, TechDocs, and `catalog-info.yaml` |
| `golden-path/skeletons/skeleton-nodejs-golden-path/` | Self-contained Node.js 20 source code, unit tests, `openapi.yaml`, `Jenkinsfile`, `sonar-project.properties`, `devfile.yaml`, Ambient Mesh Helm `/chart`, TechDocs, and `catalog-info.yaml` |
| `charts/devspaces-user-namespaces/` | GitOps Helm chart reconciled by Argo CD (`devspaces-user-namespaces`) that provisions isolated per-user Dev Spaces namespaces (`${user}-devspaces-${random}`), `ResourceQuota`, `LimitRange`, `RoleBinding`, and `DevWorkspace` from `values.yaml` |

---

## 2. Automated Dev Spaces User Namespace Check & Helm Provisioning

Before a developer opens a workspace in OpenShift Dev Spaces (where `CheCluster` auto-provisioning is disabled), their user namespace must exist and carry the Che binding labels/annotations (`che.eclipse.org/username`).

When a developer runs the **Quarkus** or **Node.js** Golden Path template:
1. **Fetch & Parse (`fetch:plain:file` + `roadiehq:utils:fs:parse`)**:
   The template downloads and parses `charts/devspaces-user-namespaces/values.yaml` from `rhdh-platform-gitops`.
2. **Idempotent Existing-Namespace Check (`users.<userSlug>`)**:
   - **If `users.<userSlug>` ALREADY exists in `values.yaml`**:
     The template **automatically skips** modifying `values.yaml` and skips opening a GitOps update, and immediately binds the new application's Dev Spaces IDE and Factory links to the user's existing namespace (`users.<userSlug>.namespace`).
   - **If `users.<userSlug>` does NOT exist in `values.yaml`**:
     The template appends the user's entry under `users:` in `charts/devspaces-user-namespaces/values.yaml` and pushes the update to `rhdh-platform-gitops` (auto-merged by `.github/workflows/auto-merge-gitops-devspaces.yml`), triggering Argo CD (`devspaces-user-namespaces`) to render the Helm chart and create the user's `Namespace`, `ResourceQuota`, `LimitRange`, `RoleBinding`, and initial `DevWorkspace`.

---

## 3. Multi-Cluster & Multi-Namespace Kubernetes Discovery

### In `catalog-info.yaml`
All Golden Path templates set **only** `backstage.io/kubernetes-id` and intentionally **omit** `backstage.io/kubernetes-namespace`:

```yaml
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: my-service
  labels:
    platform.idp/app-id: "APP-1042"
  annotations:
    platform.idp/app-id: "APP-1042"
    # Matches the backstage.io/kubernetes-id label on Kubernetes resources across all clusters & namespaces.
    # DO NOT set backstage.io/kubernetes-namespace when namespace names differ across environments/clusters.
    backstage.io/kubernetes-id: my-service
```

> **Why omit `backstage.io/kubernetes-namespace`?**
> In `@backstage/plugin-kubernetes-backend` (`KubernetesFanOutHandler`), `backstage.io/kubernetes-namespace` only accepts a **single string** and queries that exact same namespace path (`/namespaces/<ns>/...`) on every configured cluster.
> When `backstage.io/kubernetes-namespace` is **omitted**, RHDH queries cluster-wide using `?labelSelector=backstage.io/kubernetes-id=<app-name>` across every cluster in `kubernetes.clusterLocatorMethods`, automatically discovering the application's pods, deployments, services, and routes even when the namespace is named `team-payments-edev` in EDEV, `team-payments-nonprod` in NPRD, and `team-payments-prod` in PROD.

---

## 4. Required ServiceAccount Permissions on Target Clusters

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

---

## 5. Required RHDH RBAC Permissions (`rbac-policy.csv`)

In addition to the Kubernetes ServiceAccount `ClusterRole`, RHDH's internal RBAC (`permission.enabled: true`) requires permissions granted to developer roles in `rbac-policy.csv`:

```csv
p, role:default/developer, kubernetes.clusters.read, read, allow
p, role:default/developer, kubernetes.resources.read, read, allow
p, role:default/developer, kubernetes.proxy, use, allow
```
