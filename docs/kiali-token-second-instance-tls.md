# Running a Second Kiali Instance (`kiali-token`) for Red Hat Developer Hub (RHDH) With Full Thanos TLS Verification

## 1. Why the Current `kiali-token.yaml` CR Fails Against Thanos Querier

When deploying a second `Kiali` CR (`kiali-token`) with `spec.auth.strategy: token` and `spec.external_services.prometheus.auth.insecure_skip_verify: false`:

1. **TLS Certificate Error (`x509: certificate signed by unknown authority`)**:
   - OpenShift's `https://thanos-querier.openshift-monitoring.svc.cluster.local:9091` uses a certificate signed by the **OpenShift Service Serving CA (`service-ca.crt`)**.
   - Even though the Kiali Operator automatically creates `ConfigMap/kiali-token-cabundle-openshift` and mounts it inside the pod at **`/kiali-cabundle/service-ca.crt`**, Kiali's Go code (`getCABundlePaths` in `config/config.go`) **only loads `/kiali-cabundle/service-ca.crt` when `auth.strategy: openshift`**. When `auth.strategy: token`, Kiali ignores `/kiali-cabundle/service-ca.crt`!
   - **Minimal Fix (Reuses the existing `/kiali-cabundle/service-ca.crt` already mounted in the pod)**:
     Add `custom_envs` under `spec.deployment` with `SSL_CERT_FILE: /kiali-cabundle/service-ca.crt` and `SSL_CERT_DIR: /etc/pki/tls/certs`. Go's standard `crypto/x509` library automatically loads `/kiali-cabundle/service-ca.crt` into the TLS trust pool so `insecure_skip_verify: false` works without creating any extra ConfigMaps.

2. **Secret Collision (`secret_name: kiali` -> `secret_name: kiali-token`)**:
   - Change `spec.deployment.secret_name` from `kiali` to `kiali-token` so it does not collide with the primary `kiali` instance.

3. **Thanos Querier RBAC (`cluster-monitoring-view`)**:
   - Because `use_kiali_token: true` uses the pod's ServiceAccount (`kiali-token-service-account`), add `kiali-token-service-account` to the `subjects` list of the existing `ClusterRoleBinding` (or bind it to `cluster-monitoring-view`).

---

## 2. Exact `kiali-token.yaml` (Matching Your CR + Only the Required Changes)

Only **two changes** are needed inside `kiali-token.yaml`:
1. Change `secret_name: kiali` -> `secret_name: kiali-token`
2. Add `custom_envs` (`SSL_CERT_FILE` and `SSL_CERT_DIR`) under `spec.deployment`

```yaml
apiVersion: kiali.io/v1alpha1
kind: Kiali
metadata:
  name: kiali-token
  namespace: istio-system
spec:
  auth:
    strategy: token
  deployment:
    cluster_wide_access: true
    custom_envs:
      - name: SSL_CERT_FILE
        value: /kiali-cabundle/service-ca.crt
      - name: SSL_CERT_DIR
        value: /etc/pki/tls/certs
    image_digest: ""
    image_pull_policy: IfNotPresent
    instance_name: kiali-token
    logger:
      log_format: text
      log_level: info
      sampler_rate: "1"
      time_field_format: 2006-01-02T15:04:05Z07:00
    remote_cluster_resources_only: false
    replicas: 1
    secret_name: kiali-token
    view_only_mode: true
  external_services:
    grafana:
      enabled: false
      internal_url: http://grafana.istio-system:3000
      is_core: false
    prometheus:
      auth:
        insecure_skip_verify: false
        type: bearer
        use_kiali_token: true
      cache_duration: 7
      cache_enabled: true
      cache_expiration: 300
      enabled: true
      is_core: true
      thanos_proxy:
        enabled: true
        retention_period: 7d
        scrape_interval: 30s
      url: https://thanos-querier.openshift-monitoring.svc.cluster.local:9091
  istio_namespace: istio-system
  version: default
```

---

## 3. Reusing the Existing `cluster-monitoring-view` ClusterRoleBinding

Because `use_kiali_token: true` authenticates to `thanos-querier` using `kiali-token-service-account`, add `kiali-token-service-account` as a subject on the existing `cluster-monitoring-view` `ClusterRoleBinding` that the primary `kiali-service-account` uses:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kiali-cluster-monitoring-view
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-monitoring-view
subjects:
  - kind: ServiceAccount
    name: kiali-service-account
    namespace: istio-system
  - kind: ServiceAccount
    name: kiali-token-service-account
    namespace: istio-system
```

*(Or via CLI: `oc adm policy add-cluster-role-to-user cluster-monitoring-view -z kiali-token-service-account -n istio-system`)*
