# RHDH Kubernetes Plugin: Using the Cluster API URL & Enterprise CA Instead of the Service IP

This guide explains why the Red Hat Developer Hub (RHDH) Kubernetes plugin ignores `url:` and dials the internal API server ClusterIP (`172.30.0.1`) by default, and provides a 100% GitOps-native configuration (including `ServiceAccount`, RBAC, and auto-populated `Secret` manifests) so RHDH connects via the cluster API URL (`https://api.<cluster>.<base-domain>:6443`) using your Enterprise CA.

---

## 1. Why RHDH Picks Up the API Server IP (`172.30.0.1`)

In `@backstage/plugin-kubernetes-backend` (`KubernetesConnection.ts`), Backstage checks the following condition before resolving a cluster connection:

```ts
authProvider === 'serviceAccount' &&
!clusterDetails.authMetadata.serviceAccountToken &&
fs.pathExistsSync('/var/run/secrets/kubernetes.io/serviceaccount/ca.crt')
```

Whenever `authProvider: serviceAccount` is configured **without** a non-empty `serviceAccountToken`, Backstage assumes in-cluster auto-discovery:
1. It **completely ignores** the `url:` field in your `pluginConfig` / `app-config.yaml`.
2. It calls `@kubernetes/client-node`'s `kc.loadFromCluster()`, which constructs `https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT}`.
3. Because Kubernetes always injects `KUBERNETES_SERVICE_HOST` as the raw Service ClusterIP (e.g. `172.30.0.1`), outbound requests bypass `.svc` / domain rules in `NO_PROXY` (failing in environments with an egress `HTTPS_PROXY`) and do not use the external API server certificate.

Passing an explicit `serviceAccountToken: ${K8S_SA_TOKEN}` disables the `loadFromCluster()` fallback and forces RHDH to dial `url:` directly.

---

## 2. Step-by-Step GitOps Configuration

### Step 1: Create the Read-Only `ServiceAccount` and `ClusterRoleBinding`

Create a dedicated least-privilege `ServiceAccount` in the RHDH namespace (for example `rhdh`) and grant it read-only access across workload namespaces (`ClusterRole/backstage-read-only` or OpenShift's built-in `view` role):

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: rhdh-k8s-plugin
  namespace: rhdh
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: rhdh-k8s-plugin-readonly
rules:
  - apiGroups: [""]
    resources:
      - pods
      - pods/log
      - services
      - configmaps
      - endpoints
      - persistentvolumeclaims
      - replicationcontrollers
      - events
      - limitranges
      - resourcequotas
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources:
      - deployments
      - daemonsets
      - replicasets
      - statefulsets
    verbs: ["get", "list", "watch"]
  - apiGroups: ["batch"]
    resources:
      - jobs
      - cronjobs
    verbs: ["get", "list", "watch"]
  - apiGroups: ["networking.k8s.io"]
    resources:
      - ingresses
    verbs: ["get", "list", "watch"]
  - apiGroups: ["route.openshift.io"]
    resources:
      - routes
    verbs: ["get", "list", "watch"]
  - apiGroups: ["autoscaling"]
    resources:
      - horizontalpodautoscalers
    verbs: ["get", "list", "watch"]
  - apiGroups: ["metrics.k8s.io"]
    resources:
      - pods
      - nodes
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: rhdh-k8s-plugin-readonly
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: rhdh-k8s-plugin-readonly
subjects:
  - kind: ServiceAccount
    name: rhdh-k8s-plugin
    namespace: rhdh
```

---

### Step 2: Create the Auto-Populated ServiceAccount Token `Secret`

No manual token generation or external Vault secret is needed for the local cluster token. Declare a `kubernetes.io/service-account-token` `Secret` referencing `rhdh-k8s-plugin` — OpenShift's `TokenController` automatically populates `.data.token` in-cluster without storing any credential in Git:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: rhdh-k8s-plugin-token
  namespace: rhdh
  annotations:
    kubernetes.io/service-account.name: rhdh-k8s-plugin
    # If managed by Argo CD, ignore the controller-populated data block on diff:
    argocd.argoproj.io/compare-options: IgnoreExtraneous
type: kubernetes.io/service-account-token
```

> **Argo CD Note:** If your Argo CD `Application` compares `Secret` data fields strictly, add an `ignoreDifferences` entry on `/data` for `Secret/rhdh-k8s-plugin-token` so Argo CD does not report `OutOfSync` after OpenShift populates `.data.token`, `.data["ca.crt"]`, and `.data.namespace`.

Verify that OpenShift populated the token:

```bash
oc get secret rhdh-k8s-plugin-token -n rhdh -o jsonpath='{.type}{" token-bytes="}{.data.token | len}{"\n"}'
```

---

### Step 3: Inject `K8S_SA_TOKEN` into the RHDH Pod Environment

Reference `rhdh-k8s-plugin-token` (`key: token`) on your `Backstage` CR (`spec.application.extraEnvs.envs`):

```yaml
apiVersion: rhdh.redhat.com/v1alpha3
kind: Backstage
metadata:
  name: developer-hub
  namespace: rhdh
spec:
  application:
    extraEnvs:
      envs:
        - name: K8S_SA_TOKEN
          valueFrom:
            secretKeyRef:
              name: rhdh-k8s-plugin-token
              key: token
```

*(If deploying RHDH via the upstream/Red Hat Backstage Helm chart instead of the Operator CR, add the same `env` entry under `upstream.backstage.extraEnvVars`.)*

---

### Step 4: Configure the Kubernetes Dynamic Plugin (`url` + `serviceAccountToken`)

In your dynamic plugin configuration (e.g. `files/plugins/kubernetes.yaml` rendered via `tpl`), include `serviceAccountToken: ${K8S_SA_TOKEN}` alongside your API server `url`:

```yaml
plugins:
  - package: ./dynamic-plugins/dist/backstage-plugin-kubernetes
    disabled: false
  - package: ./dynamic-plugins/dist/backstage-plugin-kubernetes-backend-dynamic
    disabled: false
    pluginConfig:
      kubernetes:
        serviceLocatorMethod:
          type: multiTenant
        clusterLocatorMethods:
          - type: config
            clusters:
              - name: {{ .Values.kubernetesPlugin.clusterName | quote }}
                url: {{ printf "https://api.%s.<base-domain>:6443" .Values.kubernetesPlugin.clusterName | quote }}
                authProvider: serviceAccount
                serviceAccountToken: ${K8S_SA_TOKEN}
                skipTLSVerify: {{ .Values.kubernetesPlugin.skipTLSVerify | default false }}
                skipMetricsLookup: {{ .Values.kubernetesPlugin.skipMetricsLookup | default false }}
```

---

## 3. TLS & Enterprise CA Behavior (`caData` vs. `NODE_EXTRA_CA_CERTS`)

### Do we need `caData` when the API Server uses an Enterprise CA?
**No.** When both `caData` and `caFile` are omitted from the cluster block:
- `@backstage/plugin-kubernetes-backend` creates its `https.Agent` with `ca: undefined`.
- Node.js automatically falls back to its process-wide TLS trust store, which **includes any CA bundle configured via `NODE_EXTRA_CA_CERTS`** (or `--use-openssl-ca` in `NODE_OPTIONS`).
- Keep `skipTLSVerify: false` and omit `caData`.

> **Caution:** If you *do* set `caData` to a non-empty value, Node's `https.Agent({ ca })` overrides the default trust store for that connection and trusts *only* the certificate chain inside `caData`.

### Important OpenShift Certificate & Proxy Checks

1. **External API URL (`api.<cluster>:6443`) vs. Internal Service (`kubernetes.default.svc`):**
   - On OpenShift, custom API server certificates configured via `APIServer` (`spec.servingCerts.namedCertificates`) apply **only** to the external `https://api.<cluster>.<base-domain>:6443` endpoint.
   - The internal `https://kubernetes.default.svc:443` endpoint is always signed by OpenShift's internal kube-apiserver service CA (`/var/run/secrets/kubernetes.io/serviceaccount/ca.crt`).
   - Therefore, omit `caData` when using `https://api.<cluster>.<base-domain>:6443` with `NODE_EXTRA_CA_CERTS`; if you instead point `url` at `https://kubernetes.default.svc`, set `caFile: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt`.
2. **Node.js CA Environment Variable:**
   - Mounting a CA bundle at `/etc/pki/ca-trust/...` alone is not read by Node.js unless `NODE_EXTRA_CA_CERTS=/path/to/ca-bundle.crt` (or `--use-openssl-ca` in `NODE_OPTIONS`) is set on the `backstage-backend` container.
3. **Egress Proxy (`NO_PROXY`):**
   - If `HTTPS_PROXY` is enabled on RHDH, ensure `api.<cluster>.<base-domain>` (or a leading-dot suffix `.<base-domain>`) is included in `NO_PROXY` so RHDH connects to the OpenShift API directly rather than tunneling through the corporate forward proxy.
4. **Helm `tpl` Rendering for `files/plugins/*.yaml`:**
   - Because Helm does not template files under `files/` automatically, ensure the ConfigMap template that includes `files/plugins/kubernetes.yaml` wraps `.Files.Get` with `tpl` (e.g. `{{ tpl (.Files.Get "files/plugins/kubernetes.yaml") $ }}`).
