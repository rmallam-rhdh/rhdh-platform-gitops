# OpenShift Dev Spaces: Per-User Environment Variables Secret & Argo CD Sync Policy Guide

## 1. Overview

In Red Hat OpenShift Dev Spaces 3.x, developers often need personal or tool-specific environment variables (such as `SNYK_TOKEN`, custom Maven/npm tokens, or CLI flags) injected automatically into **all** of their workspaces when spun up.

### Why Not the Dev Spaces Dashboard UI or `CheCluster` CRD?
1. **Dev Spaces Dashboard UI (`User Preferences`)**: Only provides hardcoded tabs for `Container Registries`, `Git Services`, `Personal Access Tokens` (GitHub/GitLab/Bitbucket/Azure DevOps PATs), `Gitconfig`, `SSH Keys`, and `Device Auth Tokens`. There is no generic `KEY=VALUE` Environment Variables tab in the UI.
2. **`CheCluster` (`spec.devEnvironments.defaultComponents`)**: The `CheCluster` CRD explicitly states: *"These default components are meant to be used when a Devfile does not contain any components."* Because almost every repository's `devfile.yaml` defines its own `components:`, `defaultComponents` is ignored. Furthermore, `spec.devWorkspace.env` only sets environment variables on the DevWorkspace Operator controller pod itself, not on developer workspace containers.

### The Official Dev Spaces Mechanism: Auto-Mounted Namespace Secrets
The DevWorkspace Operator watches every `<user>-devspaces` namespace for Kubernetes `Secret` (and `ConfigMap`) resources labeled with:
- `controller.devfile.io/mount-to-devworkspace: "true"`
- `controller.devfile.io/watch-secret: "true"`

and annotated with:
- `controller.devfile.io/mount-as: env`

Any `Secret` with these metadata fields is automatically attached via `envFrom` to **every container of every workspace** in that user's namespace, regardless of which `devfile.yaml` the project uses.

---

## 2. How the IDP GitOps Pattern Works

1. **IDP Team (Day-1 Provisioning via Argo CD)**:
   When a user's `<user>-devspaces` namespace is provisioned by the IDP GitOps chart (`charts/devspaces-user-namespaces`), Argo CD creates a skeleton `Secret` named `user-workspace-env` with all required Dev Spaces labels/annotations and a placeholder key (e.g., `SNYK_TOKEN: "REPLACE_ME"`).
2. **Developer (Day-2 Self-Service Update)**:
   Because each developer has `admin` RBAC on their own `<user>-devspaces` namespace (via `RoleBinding/devspaces-user-admin`), the developer simply opens the OpenShift Console (`Workloads -> Secrets -> user-workspace-env -> Edit Secret`) and replaces `REPLACE_ME` with their personal `SNYK_TOKEN`.
3. **Automatic Workspace Injection & Reload**:
   - **New Workspaces**: Immediately receive `SNYK_TOKEN` as an environment variable (`envFrom.secretRef`) on startup.
   - **Running Workspaces**: Creating a new Secret with `controller.devfile.io/watch-secret: "true"` automatically triggers a Deployment rollout. When updating the *value* of an existing key inside `user-workspace-env` (e.g., `REPLACE_ME` -> actual token), any **already-running** workspace loads the new value once the developer clicks **Restart Workspace** in Dev Spaces (because Kubernetes `envFrom.secretRef` evaluates environment variables at container start).
4. **Argo CD Drift Protection**:
   With `ignoreDifferences` (`/data` and `/stringData`), `RespectIgnoreDifferences=true`, `ApplyOutOfSyncOnly=true`, and the resource annotation `argocd.argoproj.io/sync-options: CreateOnly=true` (or `Prune=false`), Argo CD creates the Secret if it does not exist, keeps the Application status `Synced` / `Healthy`, and **never overwrites** the developer's secret value on future GitOps syncs.

---

## 3. Secret Manifest (With Required Dev Spaces & Argo CD Annotations)

### A. Standalone Kubernetes `Secret` YAML

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: user-workspace-env
  namespace: <user>-devspaces
  labels:
    app.kubernetes.io/managed-by: rhdh-gitops
    # 1. Instructs DevWorkspace Operator to mount this Secret into every workspace in the namespace
    controller.devfile.io/mount-to-devworkspace: "true"
    # 2. Instructs DevWorkspace Operator to watch for edits and auto-reload running workspaces
    controller.devfile.io/watch-secret: "true"
  annotations:
    # 3. Mounts all Secret keys as environment variables (envFrom) in every workspace container
    controller.devfile.io/mount-as: env
    # 4. Prevents Argo CD from overwriting or deleting user-populated values after initial creation
    argocd.argoproj.io/sync-options: CreateOnly=true,Prune=false
type: Opaque
stringData:
  SNYK_TOKEN: "REPLACE_ME"
```

### B. Helm Template Snippet (`charts/devspaces-user-namespaces/templates/user-namespaces.yaml`)

Add this resource inside the `{{- range $userSlug, $u := .Values.users }}` loop in `charts/devspaces-user-namespaces/templates/user-namespaces.yaml`:

```yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: user-workspace-env
  namespace: {{ $u.namespace | quote }}
  labels:
    app.kubernetes.io/managed-by: rhdh-gitops
    controller.devfile.io/mount-to-devworkspace: "true"
    controller.devfile.io/watch-secret: "true"
  annotations:
    controller.devfile.io/mount-as: env
    argocd.argoproj.io/sync-options: CreateOnly=true,Prune=false
type: Opaque
stringData:
  SNYK_TOKEN: "REPLACE_ME"
```

### Reference Table: Labels & Annotations on the Secret

| Field | Key | Value | Purpose |
| :--- | :--- | :--- | :--- |
| **Label** | `controller.devfile.io/mount-to-devworkspace` | `"true"` | Tells the DevWorkspace Operator to mount this Secret into all workspaces in this namespace. |
| **Label** | `controller.devfile.io/watch-secret` | `"true"` | Instructs the DevWorkspace Operator to watch the Secret metadata/existence and reconcile workspace deployments when mounted Secrets are added or modified. |
| **Annotation** | `controller.devfile.io/mount-as` | `env` | Injects all key-value pairs in the Secret as environment variables (`envFrom`) into every workspace container. |
| **Annotation** | `argocd.argoproj.io/sync-options` | `CreateOnly=true,Prune=false` | Ensures Argo CD only creates the initial skeleton Secret on Day 1 and never overwrites or prunes the developer's custom values during subsequent syncs. |

---

## 4. Argo CD `Application` Configuration (`syncPolicy` & `ignoreDifferences`)

In the Argo CD `Application` that manages the per-user namespaces (`argocd/apps/devspaces-user-namespaces.yaml`), configure both `syncPolicy` and `ignoreDifferences` as shown below:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: devspaces-user-namespaces
  namespace: openshift-gitops
  labels:
    app.kubernetes.io/part-of: idp-platform
    app.kubernetes.io/component: devspaces-tenants
  annotations:
    argocd.argoproj.io/sync-wave: "4"
spec:
  project: default
  source:
    repoURL: https://github.com/rmallam-rhdh/rhdh-platform-gitops
    targetRevision: main
    path: charts/devspaces-user-namespaces
    helm:
      valueFiles:
        - values.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: openshift-devspaces
  syncPolicy:
    automated:
      prune: false
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
      # 1. Tells automated selfHeal to honor the ignoreDifferences rules below
      - RespectIgnoreDifferences=true
      # 2. Only applies resources that are actually OutOfSync during a sync operation
      - ApplyOutOfSyncOnly=true
      - SkipDryRunOnMissingResource=true
  ignoreDifferences:
    # 3. Ignore user-updated Secret payloads so Argo CD never treats user tokens as drift
    - group: ""
      kind: Secret
      name: user-workspace-env
      jsonPointers:
        - /data
        - /stringData
    - group: workspace.devfile.io
      kind: DevWorkspace
      jsonPointers:
        - /spec/started
        - /spec/contributions
        - /status
        - /metadata/labels
        - /metadata/annotations
        - /metadata/finalizers
    - group: workspace.devfile.io
      kind: DevWorkspaceTemplate
      jsonPointers:
        - /metadata/ownerReferences
        - /metadata/annotations
```

### Why Each Argo CD Setting Matters

1. **`ignoreDifferences` on `/data` and `/stringData` for `Secret/user-workspace-env`**:
   When the user updates `SNYK_TOKEN` in the OpenShift Console, Kubernetes modifies `/data/SNYK_TOKEN`. Ignoring `/data` and `/stringData` ensures Argo CD still shows the Secret as `Synced`.
2. **`RespectIgnoreDifferences=true` in `syncOptions`**:
   By default, Argo CD's `ignoreDifferences` only affects the UI diff view unless `RespectIgnoreDifferences=true` is enabled. With `RespectIgnoreDifferences=true`, Argo CD's `selfHeal` controller will not trigger a self-heal sync when a user edits `/data`.
3. **`ApplyOutOfSyncOnly=true` in `syncOptions` + `argocd.argoproj.io/sync-options: CreateOnly=true`**:
   Without `ApplyOutOfSyncOnly=true` (and `CreateOnly=true` on the Secret), if another resource in the same Argo CD Application becomes `OutOfSync` (for example, a new user namespace is added to `values.yaml`), Argo CD would re-apply all manifests in the Application—which would overwrite `/data/SNYK_TOKEN` back to `"REPLACE_ME"`. Together, `ApplyOutOfSyncOnly=true` and `CreateOnly=true` guarantee that once `user-workspace-env` is created in `<user>-devspaces`, Argo CD never touches its data again.

---

## 5. Developer Instructions: Updating Your `SNYK_TOKEN`

Once the IDP team has deployed the templated `user-workspace-env` Secret to each `<user>-devspaces` namespace, developers can set or rotate their token at any time:

### Option 1: Via OpenShift Web Console
1. Log in to the OpenShift Web Console and switch to the **Developer** or **Administrator** perspective.
2. Select your personal Dev Spaces project: **`<your-username>-devspaces`**.
3. Navigate to **Workloads → Secrets** and click **`user-workspace-env`**.
4. Click **Actions → Edit Secret**.
5. Change the value of **`SNYK_TOKEN`** from `REPLACE_ME` to your real Snyk API token (you can also click **Add key/value** to add any additional personal environment variables you need across your workspaces).
6. Click **Save**.

### Option 2: Via `oc` CLI
```bash
oc patch secret user-workspace-env \
  -n <your-username>-devspaces \
  --type merge \
  -p '{"stringData":{"SNYK_TOKEN":"<your-actual-snyk-token>"}}'
```

### Verifying Inside Your Dev Spaces Workspace
1. If you already had a workspace **Running** while you edited `user-workspace-env`, click **Restart Workspace** (or Stop/Start) in the Dev Spaces dashboard so the container restarts and loads the updated `envFrom` Secret values. (Any newly started workspace loads it automatically).
2. Open a terminal inside your Dev Spaces workspace and run:
```bash
echo $SNYK_TOKEN
```
You will see your updated token loaded in the container environment.
