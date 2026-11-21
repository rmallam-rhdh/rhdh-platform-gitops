# ${{ values.appName }} (`${{ values.appId | default("APP-1001") }}`)

${{ values.appDescription }}

| Attribute | Value |
| :--- | :--- |
| **Application ID (`APPID`)** | `${{ values.appId | default("APP-1001") }}` |
| **Owning Squad (`groupName`)** | `${{ values.groupName | default("group:default/developers") }}` |
| **System** | `${{ values.systemName | default("plugin-kitchen-sink") }}` |
| **Provided OpenAPI Spec** | `${{ values.appName }}-api` (`/openapi.yaml`) |
| **Dev Spaces User Namespace** | `${{ values.workspaceNamespace | default("cluster-admin-devspaces-r7k2m") }}` |
| **Multi-Cluster Kubernetes ID** | `backstage.io/kubernetes-id: ${{ values.kubernetesId | default(values.appName) }}` |
| **Vault Enterprise Namespace** | `${{ values.vaultNamespace | default("payments/nonprod") }}` (`${{ values.vaultSecretsPath | default("ledger-service") }}`) |

---

## 1. Developer Workspace (OpenShift Dev Spaces)

Your isolated Dev Spaces namespace **`${{ values.workspaceNamespace | default("cluster-admin-devspaces-r7k2m") }}`** is managed via GitOps in `charts/devspaces-user-namespaces/values.yaml` and reconciled by Argo CD (`devspaces-user-namespaces`).

* **Open Workspace directly in Dev Spaces:**
  [${{ values.devSpacesBaseUrl }}/dashboard/#/ide/${{ values.workspaceNamespace | default("cluster-admin-devspaces-r7k2m") }}/${{ values.appName }}](${{ values.devSpacesBaseUrl }}/dashboard/#/ide/${{ values.workspaceNamespace | default("cluster-admin-devspaces-r7k2m") }}/${{ values.appName }})
* **Launch via Dev Spaces Factory URL:**
  [${{ values.devSpacesBaseUrl }}#https://github.com/${{ values.githubOwner }}/${{ values.appName }}?new&devfilePath=devfile.yaml&namespace=${{ values.workspaceNamespace | default("cluster-admin-devspaces-r7k2m") }}](${{ values.devSpacesBaseUrl }}#https://github.com/${{ values.githubOwner }}/${{ values.appName }}?new&devfilePath=devfile.yaml&namespace=${{ values.workspaceNamespace | default("cluster-admin-devspaces-r7k2m") }})

---

## 2. CI/CD & Quality Gate (`Jenkinsfile` + SonarQube)

Jenkinsfile stages: **Unit Tests (JUnit 5 / Java 21) -> SonarQube Quality Gate -> Helm Lint & Template**.

* **Jenkins Pipeline Job:** `${{ values.jenkinsJobFullName | default("demo/" + values.appName) }}`
* **SonarQube Project Key:** `${{ values.sonarProjectKey | default(values.appName) }}` (`${{ values.sonarHostUrl }}`)

---

## 3. Multi-Cluster Runtime & Ambient Service Mesh (`/chart`)

North-south traffic flows through **OpenShift Route -> Kubernetes Gateway API (`Gateway`) -> `HTTPRoute` -> Service**.
* **Ambient Mesh Enrollment:** `istio.io/dataplane-mode=ambient` with `PeerAuthentication` (`STRICT` mTLS) and `AuthorizationPolicy` (deny-all + explicit ingress gateway allow).
* **Multi-Cluster Discovery:** Resources carry `backstage.io/kubernetes-id=${{ values.appName }}` and `platform.idp/app-id=${{ values.appId | default("APP-1001") }}`. Because `backstage.io/kubernetes-namespace` is omitted in `catalog-info.yaml`, RHDH discovers deployments and pods across **EDEV, NPRD, and PROD clusters** regardless of per-environment namespace naming.
