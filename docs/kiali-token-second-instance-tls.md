# Running a Second Kiali Instance (`kiali-token`) for Red Hat Developer Hub (RHDH) With Full Thanos TLS Verification

## 1. Why a Second Kiali Instance (`auth.strategy: token`) Is Needed

In Red Hat OpenShift Service Mesh 3 (OSSM 3), the default Kiali instance (`kiali` in `istio-system`) is typically configured with `spec.auth.strategy: openshift` so human users can log into the Kiali web console via OpenShift OAuth.

However, the **RHDH / Backstage Kiali Backend Plugin** (`@backstage-community/plugin-kiali-backend`) authenticates non-interactively by calling `POST /api/authenticate` on Kiali:
- **`auth.strategy: openshift`** requires a browser-based OpenShift OAuth authorization code redirect flow and **does not accept** a raw Kubernetes `ServiceAccount` bearer token on `POST /api/authenticate`.
- **`auth.strategy: token`** (or `anonymous`) accepts a standard Kubernetes `ServiceAccount` token (`serviceAccountToken: ${KUBE_SA_TOKEN}`) via `POST /api/authenticate`.

To keep `auth.strategy: openshift` for human users on the primary `kiali` UI while allowing RHDH to query Kiali programmatically with RBAC, deploy a second `Kiali` custom resource (`kiali-token`) in `istio-system` with `spec.auth.strategy: token`.

---

## 2. Two Root Causes When Deploying a Second `Kiali` CR (`auth.strategy: token`)

When deploying a second `Kiali` instance with `auth.strategy: token` in `istio-system`, two issues commonly occur:

### Issue A: Thanos Querier `x509: certificate signed by unknown authority` Error
OpenShift's `https://thanos-querier.openshift-monitoring.svc.cluster.local:9091` endpoint presents a TLS certificate signed by the **OpenShift Service Serving Certificate Signer (`service-ca.crt`)**.

In Kiali v2.x (`config/config.go` -> `getCABundlePaths(authStrategy)`), the CA bundle files loaded into Kiali's TLS trust pool depend on `spec.auth.strategy`:

| `spec.auth.strategy` | CA Bundle Files Loaded by Kiali (`getCABundlePaths`) |
|---|---|
| `openshift` | `/kiali-cabundle/additional-ca-bundle.pem`<br>`/kiali-cabundle/oauth-server-ca.crt`<br>**`/kiali-cabundle/service-ca.crt`** *(OpenShift Service CA)*<br>`/var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt` |
| `token` / `anonymous` | **Only `/kiali-cabundle/additional-ca-bundle.pem`** |

Because Kiali **skips loading `/kiali-cabundle/service-ca.crt`** when `auth.strategy` is switched from `openshift` to `token` (and because `external_services.prometheus.auth.ca_file` is deprecated and ignored in Kiali v2.x), Kiali fails to verify `thanos-querier`'s TLS certificate even though the Kiali Operator already mounts `/kiali-cabundle/service-ca.crt` inside the pod!

#### How to Reuse the Existing Mounted `/kiali-cabundle/service-ca.crt` Bundle (Zero Extra ConfigMaps)
Because Kiali is a Go binary, Go's standard `crypto/x509` library honors the `SSL_CERT_FILE` and `SSL_CERT_DIR` environment variables when initializing `x509.SystemCertPool()`.

By setting:
```yaml
spec:
  deployment:
    custom_envs:
      - name: SSL_CERT_FILE
        value: /kiali-cabundle/service-ca.crt
      - name: SSL_CERT_DIR
        value: /etc/pki/tls/certs
```
Kiali automatically trusts **both** the operator-mounted `/kiali-cabundle/service-ca.crt` (from `<instance_name>-cabundle-openshift`) and the container's system CA roots (`/etc/pki/tls/certs`), allowing `insecure_skip_verify: false` on Prometheus / Thanos Querier without creating or copying any extra ConfigMaps.

---

### Issue B: Resource Collisions Between Two `Kiali` CRs in `istio-system`
In the Kiali Operator (`roles/default/kiali-deploy/templates/openshift/deployment.yaml`), child resource names are derived from `spec.deployment.instance_name` (which defaults to `kiali`) and `spec.deployment.secret_name` (which also defaults to `kiali`):

- `ConfigMap`: `{{ instance_name }}`
- `Service` & `Route`: `{{ instance_name }}`
- Serving TLS Cert `Secret`: `{{ instance_name }}-cert-secret`
- OpenShift Service CA `ConfigMap`: `{{ instance_name }}-cabundle-openshift`
- Signing Key `Secret`: `{{ instance_name }}-signing-key`
- `ServiceAccount`: `{{ instance_name }}-service-account`
- Login `Secret`: `{{ secret_name }}`

If two `Kiali` CRs in `istio-system` share the default `instance_name: kiali` or `secret_name: kiali`, they overwrite each other's `Service`, TLS serving certificate (`kiali-cert-secret`), and session signing keys.

Therefore, the second `Kiali` CR **must** set unique values for both `spec.deployment.instance_name` and `spec.deployment.secret_name` (e.g. `kiali-token`), and its dedicated ServiceAccount (`kiali-token-service-account`) must be bound to the `cluster-monitoring-view` ClusterRole so `thanos-querier` accepts its bearer token.

---

## 3. Complete `Kiali` CR & RBAC Manifest (`kiali-token`)

Apply the following manifest to deploy `kiali-token` in `istio-system` with full TLS verification (`insecure_skip_verify: false`) against OpenShift Thanos Querier:

```yaml
apiVersion: kiali.io/v1alpha1
kind: Kiali
metadata:
  name: kiali-token
  namespace: istio-system
spec:
  istio_namespace: istio-system
  auth:
    strategy: token
  deployment:
    # Must be unique so resources do not collide with the primary 'kiali' (openshift auth) instance
    instance_name: kiali-token
    secret_name: kiali-token
    accessible_namespaces:
      - "**"
    ingress:
      enabled: true
    # Reuse the operator-mounted /kiali-cabundle/service-ca.crt + system CA roots via Go x509 env vars
    custom_envs:
      - name: SSL_CERT_FILE
        value: /kiali-cabundle/service-ca.crt
      - name: SSL_CERT_DIR
        value: /etc/pki/tls/certs
  external_services:
    istio:
      root_namespace: istio-system
    prometheus:
      url: https://thanos-querier.openshift-monitoring.svc.cluster.local:9091
      auth:
        type: bearer
        use_kiali_token: true
        insecure_skip_verify: false
      thanos_proxy:
        enabled: true
    custom_dashboards:
      prometheus:
        url: https://thanos-querier.openshift-monitoring.svc.cluster.local:9091
        auth:
          type: bearer
          use_kiali_token: true
          insecure_skip_verify: false
    grafana:
      enabled: false
---
# Grant kiali-token-service-account permission to query OpenShift Thanos Querier
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kiali-token-cluster-monitoring-view
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-monitoring-view
subjects:
  - kind: ServiceAccount
    name: kiali-token-service-account
    namespace: istio-system
```

---

## 4. RHDH `app-config.yaml` Configuration

Point the RHDH Kiali plugin at the in-cluster `kiali-token` Service (`https://kiali-token.istio-system.svc:20001`) using the RHDH ServiceAccount token (`${KUBE_SA_TOKEN}`):

```yaml
kiali:
  providers:
    - name: default
      url: https://kiali-token.istio-system.svc:20001
      serviceAccountToken: ${KUBE_SA_TOKEN}
      skipTLSVerify: true
```

---

## 5. Verification From Inside the RHDH Pod

```bash
oc exec -n rhdh deploy/backstage-developer-hub -c backstage-backend -- sh -c '
  echo "=== 1. Check Kiali Auth Strategy (/api/auth/info) ==="
  curl -sk https://kiali-token.istio-system.svc:20001/api/auth/info && echo ""

  echo "=== 2. Authenticate with ServiceAccount Token (POST /api/authenticate) ==="
  curl -sk -i -c /tmp/kiali.cookie \
    -H "X-Auth-Type-Kiali-UI: 1" \
    --data-urlencode "token=${KUBE_SA_TOKEN}" \
    https://kiali-token.istio-system.svc:20001/api/authenticate && echo ""

  echo "=== 3. Query Kiali Status & Verify Prometheus/Thanos Health ==="
  curl -sk -b /tmp/kiali.cookie https://kiali-token.istio-system.svc:20001/api/status && echo ""
'
```
