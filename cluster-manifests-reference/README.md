# Live Cluster Manifests Reference (`rosa-rwx5g`)

This folder contains the **fully rendered, live Kubernetes/OpenShift manifests** exported directly from cluster `rosa-rwx5g` (with no Helm `{{ ... }}` or Backstage Scaffolder `${{ ... }}` template expressions), so you can read or `oc apply -f` them directly.

## Directory Structure

### `01-devspaces-platform/`
- [`checluster-devspaces.yaml`](./01-devspaces-platform/checluster-devspaces.yaml): Live `CheCluster/devspaces` in `openshift-devspaces` with `spec.devEnvironments.defaultNamespace.autoProvision: false`, container resource caps, default container resources, and restricted security context.
- [`devworkspace-operator-config-global.yaml`](./01-devspaces-platform/devworkspace-operator-config-global.yaml): Global `DevWorkspaceOperatorConfig/devworkspace-operator-config` in `openshift-devspaces` enforcing resource caps and workspace pruning cronjob.
- [`devworkspace-config-che.yaml`](./01-devspaces-platform/devworkspace-config-che.yaml): Che-managed `DevWorkspaceOperatorConfig/devworkspace-config` in `openshift-devspaces`.

### `02-argocd-applications/`
- [`application-devspaces.yaml`](./02-argocd-applications/application-devspaces.yaml): Argo CD `Application` managing `charts/devspaces`.
- [`application-devspaces-user-namespaces.yaml`](./02-argocd-applications/application-devspaces-user-namespaces.yaml): Argo CD `Application` watching `tenants/devspaces-namespaces/**` (`directory.recurse: true`) with `ignoreDifferences` for runtime `DevWorkspace` fields.
- [`application-developer-hub.yaml`](./02-argocd-applications/application-developer-hub.yaml): Argo CD `Application` managing `charts/developer-hub`.

### `03-rhdh-golden-path/`
- [`template-gitops-devspaces-namespace.yaml`](./03-rhdh-golden-path/template-gitops-devspaces-namespace.yaml): Rendered RHDH Scaffolder `Template` (`acme-gitops-devspaces-namespace`) with concrete cluster URLs.
- [`template-open-devspaces-namespace.yaml`](./03-rhdh-golden-path/template-open-devspaces-namespace.yaml): Rendered Day-2 `Template` (`acme-open-devspaces-namespace`) for opening an existing service in a pre-created namespace.
- [`template-node-udi-devspaces.yaml`](./03-rhdh-golden-path/template-node-udi-devspaces.yaml): Rendered Node.js UDI `Template` (`acme-node-udi-devspaces`).
- [`template-start-feature-devspaces.yaml`](./03-rhdh-golden-path/template-start-feature-devspaces.yaml): Rendered Day-2 feature branch `Template` (`acme-start-feature-devspaces`).
- [`configmap-rhdh-golden-path.yaml`](./03-rhdh-golden-path/configmap-rhdh-golden-path.yaml): Full live `ConfigMap/rhdh-golden-path` in namespace `rhdh`.
- [`backstage-developer-hub.yaml`](./03-rhdh-golden-path/backstage-developer-hub.yaml): Live `Backstage/developer-hub` CR in namespace `rhdh`.

### `04-provisioned-user-namespace-cluster-admin-devspaces-r7k2m/`
Live objects created in the pre-created `${user}-devspaces-${random}` namespace (`cluster-admin-devspaces-r7k2m`):
- [`all-in-one-tenant-bundle.yaml`](./04-provisioned-user-namespace-cluster-admin-devspaces-r7k2m/all-in-one-tenant-bundle.yaml): Single multi-document YAML containing `Namespace` + `ResourceQuota` + `LimitRange` + `RoleBinding` + `DevWorkspace` ready for `oc apply -f`.
- [`01-namespace.yaml`](./04-provisioned-user-namespace-cluster-admin-devspaces-r7k2m/01-namespace.yaml): `Namespace/cluster-admin-devspaces-r7k2m` showing `che.eclipse.org/username: cluster-admin` annotation and `app.kubernetes.io/component: workspaces-namespace` + `app.kubernetes.io/part-of: che.eclipse.org` labels.
- [`02-resourcequota-devspaces-tenant-quota.yaml`](./04-provisioned-user-namespace-cluster-admin-devspaces-r7k2m/02-resourcequota-devspaces-tenant-quota.yaml): `ResourceQuota/devspaces-tenant-quota` (`spec.hard` + `status.used`).
- [`03-limitrange-devspaces-container-limits.yaml`](./04-provisioned-user-namespace-cluster-admin-devspaces-r7k2m/03-limitrange-devspaces-container-limits.yaml): `LimitRange/devspaces-container-limits`.
- [`04-rolebinding-devspaces-user-admin.yaml`](./04-provisioned-user-namespace-cluster-admin-devspaces-r7k2m/04-rolebinding-devspaces-user-admin.yaml): `RoleBinding/devspaces-user-admin` granting `ClusterRole/admin` to `User/cluster-admin`.
- [`05-devworkspace-rhdh-gitops-ns-demo.yaml`](./04-provisioned-user-namespace-cluster-admin-devspaces-r7k2m/05-devworkspace-rhdh-gitops-ns-demo.yaml): `DevWorkspace/rhdh-gitops-ns-demo` (`workspace490b6f3b7d404b94`).
- [`06-configmap-che-user-settings.yaml`](./04-provisioned-user-namespace-cluster-admin-devspaces-r7k2m/06-configmap-che-user-settings.yaml) & [`07-configmap-sync-workspaces-config.yaml`](./04-provisioned-user-namespace-cluster-admin-devspaces-r7k2m/07-configmap-sync-workspaces-config.yaml): ConfigMaps automatically injected by the Dev Spaces operator upon detecting the namespace labels/annotations.
