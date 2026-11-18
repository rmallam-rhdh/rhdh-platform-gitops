# OpenShift Service Mesh 3 (Ambient) Chart

Helm chart deploying Red Hat OpenShift Service Mesh 3 (Sail Operator + Kiali) custom resources in **Ambient** mode (`ztunnel` + optional per-namespace waypoints).

> The **Red Hat OpenShift Service Mesh 3** (`sailoperator`) and **Kiali** operators must already be installed in `openshift-operators`. Consistent with platform GitOps policy, this chart renders custom resources only (never `Subscription` or `OperatorGroup`).

## Resources Created

| Resource | Namespace | Condition / Sync Wave | Purpose |
|---|---|---|---|
| `Namespace` (`istio-system`, `istio-cni`, `ztunnel`) | cluster | `createNamespaces: true` | Control-plane, CNI, and node-proxy namespaces |
| `Istio` (`sailoperator.io/v1`) | cluster (targets `istio.namespace`) | wave `3` | `istiod` control plane (`profile: ambient`, `discoverySelectors`) |
| `IstioCNI` (`sailoperator.io/v1`) | cluster (targets `istioCni.namespace`) | wave `2` | Ambient traffic redirection CNI plugin |
| `ZTunnel` (`sailoperator.io/v1`) | cluster (targets `ztunnel.namespace`) | wave `3` | L4 HBONE / mTLS node proxy DaemonSet |
| `Kiali` (`kiali.io/v1alpha1`) | `kiali.namespace` | wave `4` | Mesh topology & mTLS observability UI |
| `ServiceMonitor`, `PodMonitor`, `ClusterRoleBinding` | `istio-system` / `ztunnel` | `telemetry.enabled: true` (wave `4`) | User-workload Prometheus scraping & Kiali metrics view |
| `PeerAuthentication` (`security.istio.io/v1`) | `istio.namespace` (`istio-system`) | `mtls.enabled: true` (wave `4`) | Mesh-wide inbound mTLS enforcement (`STRICT` / `PERMISSIVE` / `DISABLE`) |

---

## Enabling Mesh-Level mTLS

In Istio / OpenShift Service Mesh 3, a **selector-less `PeerAuthentication` in the mesh root namespace** (`istio.namespace`, default `istio-system`) sets the **mesh-wide default inbound mTLS mode** for every namespace enrolled in the mesh (`istio.io/dataplane-mode: ambient` or sidecar-injected).

### 1. Enable via `values.yaml` (GitOps Recommended)

Edit `charts/service-mesh/values.yaml` and commit:

```yaml
mtls:
  enabled: true
  mode: STRICT     # STRICT | PERMISSIVE | DISABLE
  name: default
```

Or pass via Helm / Argo CD parameters:

```bash
helm upgrade --install service-mesh charts/service-mesh \
  --namespace istio-system \
  --set mtls.enabled=true \
  --set mtls.mode=STRICT
```

### 2. Supported Modes

| `mtls.mode` | Behavior |
|---|---|
| `STRICT` | *(Recommended for zero-trust)* Rejects plaintext inbound TCP connections to mesh-enrolled pods; all pod-to-pod traffic must traverse mTLS / HBONE (`ztunnel` or sidecar). |
| `PERMISSIVE` | Accepts both mTLS/HBONE and plaintext traffic (useful during phased migration while onboarding legacy clients). |
| `DISABLE` | Disables inbound mTLS requirement at the mesh root (not recommended outside troubleshooting). |

### 3. Ambient Mesh Ingress & Exception Notes

* **Non-mesh namespaces are unaffected:** Namespaces without `istio.io/dataplane-mode: ambient` (such as `rhdh`, `cnpg`, or `squid`) are outside `ztunnel` capture and continue operating normally.
* **Kubelet health probes keep working:** `IstioCNI` automatically SNATs node-local `kubelet` readiness/liveness probes so `STRICT` mTLS does not break pod health checks.
* **North-south ingress into `STRICT` namespaces:**
  * **Istio `Gateway` + `HTTPRoute`:** Works automatically with `STRICT` because the Istio gateway pod communicates with ambient backends over HBONE mTLS.
  * **Direct OpenShift `Route` (`edge` / `reencrypt`):** The OpenShift HAProxy router is outside the mesh and forwards plaintext to target pods. Either front the service with an Istio `Gateway`, or add a **namespace-scoped or port-scoped `PeerAuthentication` override** in that specific application namespace:
    ```yaml
    apiVersion: security.istio.io/v1
    kind: PeerAuthentication
    metadata:
      name: allow-router-ingress
      namespace: my-legacy-app
    spec:
      selector:
        matchLabels:
          app.kubernetes.io/name: my-legacy-app
      mtls:
        mode: STRICT
      portLevelMtls:
        8080:
          mode: PERMISSIVE
    ```
  *(Istio evaluates `PeerAuthentication` from most specific to least specific: **workload `portLevelMtls` → workload → namespace → mesh root in `istio-system`**.)*

---

## Verify

### Lint & Template Unit Tests

```bash
helm lint charts/service-mesh
./charts/service-mesh/tests/test-chart.sh
```

### Cluster Verification After Sync

```bash
# Confirm mesh-wide PeerAuthentication in root namespace
oc get peerauthentication -n istio-system

# Inspect ztunnel HBONE / mTLS connection logs
oc logs -n ztunnel -l app=ztunnel --tail=50
```

In **Kiali**, open **Graph** → enable **Display → Security** to see the lock icon across mesh edges and the **Mesh-wide TLS** badge in the masthead.
