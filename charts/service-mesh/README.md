# OpenShift Service Mesh 3 (Ambient) Chart

Helm chart deploying Red Hat OpenShift Service Mesh 3 (Sail Operator + Kiali) custom resources in **Ambient** mode (`ztunnel` + optional per-namespace waypoints).

> The **Red Hat OpenShift Service Mesh 3** (`sailoperator`) and **Kiali** operators must already be installed in `openshift-operators`. Consistent with platform GitOps policy, this chart renders custom resources only (never `Subscription` or `OperatorGroup`).

* **Multi-Tenant Ingress Patterns (`ListenerSet` vs. F5 CIS Operator):** see [INGRESS-PATTERNS.md](INGRESS-PATTERNS.md).
* **Standalone mesh-wide `PeerAuthentication` manifest:** see [../../examples/mesh-peerauthentication.example.yaml](../../examples/mesh-peerauthentication.example.yaml).

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

## Enabling Mesh-Level mTLS (`istio-system`)

In Istio / OpenShift Service Mesh 3, placing a **`PeerAuthentication` with no `selector` in the mesh root namespace (`istio-system`)** sets the **mesh-wide default inbound mTLS policy** for every namespace enrolled in the mesh (`istio.io/dataplane-mode: ambient` or sidecar-injected). Application teams do not need to create `PeerAuthentication` objects in their own namespaces.

### Rendered Mesh-Wide Resource (`istio-system`)

When `mtls.enabled: true` is set (or if applied directly from [examples/mesh-peerauthentication.example.yaml](../../examples/mesh-peerauthentication.example.yaml)), this is the exact mesh-wide manifest created in `istio-system`:

```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: istio-system
spec:
  mtls:
    mode: STRICT
```

> **Why there is no `selector`:** In Istio, omitting `spec.selector` inside the root namespace (`istio-system`) makes the policy **mesh-wide**. Adding a `selector` inside `istio-system` would restrict the rule to pods inside `istio-system` only instead of the entire mesh.

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
| `DISABLE` | Disables inbound mTLS requirement at the mesh root (not supported for Ambient HBONE traffic; troubleshooting only). |

### 3. How Istio Scope Precedence Works (`Mesh → Namespace → Workload`)

Istio evaluates `PeerAuthentication` from narrowest scope to widest scope:

| Scope | `metadata.namespace` | `spec.selector` | Effect |
|---|---|---|---|
| **1. Mesh-Wide *(this chart)*** | `istio-system` | **Omitted** | Default for every mesh-enrolled pod across the entire cluster |
| **2. Namespace-Wide** | `<app-namespace>` | **Omitted** | Overrides the mesh-wide rule for all pods in `<app-namespace>` |
| **3. Workload / Port Exception** | `<app-namespace>` | `matchLabels: ...` | Overrides the rule for one specific app (and optionally one port via `portLevelMtls`) |

### 4. Ambient Mesh Behavior & North-South Ingress

* **Non-mesh namespaces are unaffected:** Namespaces without `istio.io/dataplane-mode: ambient` (such as `rhdh`, `cnpg`, or `squid`) are outside `ztunnel` capture and continue operating normally.
* **Kubelet health probes keep working:** `IstioCNI` automatically SNATs node-local `kubelet` readiness/liveness probes so `STRICT` mTLS does not break pod health checks.
* **North-south ingress into `STRICT` namespaces:**
  * **Recommended:** Route external traffic through an **Istio `Gateway` + `HTTPRoute`** so Gateway-to-Pod traffic uses HBONE `STRICT` mTLS end-to-end with zero `PERMISSIVE` exceptions. For self-service per-app hostnames without wildcard certificates (using either **F5 CIS Operator** on OCP 4.20 or **Gateway API `ListenerSet`**), see [INGRESS-PATTERNS.md](INGRESS-PATTERNS.md).
  * **Optional Legacy Escape Hatch (Direct OpenShift `Route`):** Because OpenShift's HAProxy router sits outside the mesh and forwards plaintext to target pods, a legacy app exposed directly via an `edge`/`reencrypt` OpenShift `Route` would be blocked by mesh-wide `STRICT`. If needed temporarily during migration, that app team can add a port-level `PERMISSIVE` override in **their own application namespace** (paired with a Kubernetes `NetworkPolicy` allowing `openshift-ingress` only):
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
