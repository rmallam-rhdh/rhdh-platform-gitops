# Multi-Tenant Mesh Ingress Without Wildcard Certificates

When `STRICT` mesh-wide mTLS is enabled (`mtls.enabled: true` in `charts/service-mesh`) and enterprise PKI policy **prohibits wildcard TLS certificates** (requiring one Venafi/enterprise leaf certificate per application hostname), teams need a way to onboard new application hostnames **without**:

1. Punching `PERMISSIVE` holes in the service mesh,
2. Filing manual platform tickets to edit a central `Gateway` CR on every new app, or
3. Hitting the Kubernetes Gateway API **64-listener limit** per `Gateway` CR.

This document covers the **two self-service multi-tenant architectures** for solving this—one available **today on OpenShift 4.20 with F5 CIS Operator**, and one using native **Gateway API `ListenerSet` (`XListenerSet`)** as OpenShift upgrades its bundled Gateway API CRDs.

---

## Comparison at a Glance

| Capability | Option 1: F5 CIS Operator + 1-Listener Istio `Gateway` | Option 2: Gateway API `ListenerSet` (`XListenerSet`) |
|---|---|---|
| **Available on OpenShift 4.20 + OSSM 3.4?** | **Yes — GA & supported today** (uses Gateway API `v1.2.1` + F5 CIS CRDs) | **Future OCP release** (OCP 4.20 ships Gateway API `v1.2.1`; `ListenerSet` requires v1.3+ experimental / v1.5 standard) |
| **Wildcard TLS cert needed?** | **No** (per-app leaf cert on F5; 1 single-SAN leaf cert on Istio `Gateway`) | **No** (per-app leaf cert on each `ListenerSet`) |
| **Central `Gateway` edits per new app?** | **Zero** (`shared-gw` has 1 static listener forever) | **Zero** (`shared-gw` sets `allowedListeners` once) |
| **Hits 64-listener `Gateway` limit?** | **Never** (1 listener on `Gateway`; F5 handles SNI scale) | **Never** (each `ListenerSet` CR has its own budget) |
| **Cross-namespace `ReferenceGrant` needed?** | **No** (`TLSProfile` + Venafi `Secret` live in the app namespace) | **No** (`ListenerSet` + Venafi `Secret` live in the app namespace) |
| **End-to-end encryption & Mesh mTLS** | `Client --[TLS]--> F5 --[TLS/mTLS]--> Istio GW --[HBONE STRICT]--> Pod` | `Client --[SNI Passthrough]--> Istio GW --[HBONE STRICT]--> Pod` |

---

## Option 1: F5 CIS Operator + Single-Listener Istio `Gateway` *(Recommended on OCP 4.20 On-Prem)*

On-prem OpenShift clusters running the **F5 Container Ingress Services (CIS) Operator** (`cis.f5.com/v1`) can use F5 `VirtualServer` + `TLSProfile` in each application namespace as the per-hostname TLS front door, re-encrypting into a **single shared listener** on the Istio `Gateway`.

### Architecture

```
Browser (https://payments.corp.com)
   │  1. Public Venafi leaf cert (CN=payments.corp.com)
   ▼
F5 BIG-IP VIP (programmed by VirtualServer + TLSProfile in `payments` ns)
   │  2. Re-encrypts to single backend SAN (CN=istio-gateway.ocp.internal)
   │     while preserving HTTP `Host: payments.corp.com` header
   ▼
Shared Istio Gateway (`shared-gw` in `gw-ingress` — 1 HTTPS listener, no hostname filter)
   │  3. Matches `HTTPRoute` for `payments.corp.com`; forwards over HBONE STRICT mTLS
   ▼
App Pod (`payments-svc` in `payments` ns — STRICT mTLS enforced by ztunnel)
```

### Why Only 1 Listener Is Needed on the Istio `Gateway` (Zero Wildcards)

* **Hop 1 (`Browser → F5`):** The browser checks `payments.corp.com` against the app team's per-host Venafi certificate terminated on F5 (`clientSSL`).
* **Hop 2 (`F5 → Istio Gateway`):** Now **F5 itself** is the TLS client connecting to one backend service (`shared-gw-istio`). Because F5 only talks to one backend target, `shared-gw` only needs **one single-hostname leaf certificate** (`CN=istio-gateway.ocp.internal` — not a wildcard). Omitting `hostname:` on that single `Gateway` listener tells Envoy to accept all HTTP `Host` headers inside that trusted encrypted tunnel and dispatch each request to the matching app `HTTPRoute`.

### Step 1 — Platform Team Setup (One-Time in `gw-ingress`)

Platform issues one leaf certificate (`istio-gateway-leaf-tls`, `CN=istio-gateway.ocp.internal`) and creates `shared-gw` **once**:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: shared-gw
  namespace: gw-ingress
spec:
  gatewayClassName: istio
  listeners:
    - name: https-from-f5
      port: 443
      protocol: HTTPS
      # Omit `hostname` so this single listener accepts any HTTP Host header from F5.
      tls:
        # Optional hardening: use `mode: MUTUAL` with F5's client cert so nothing on
        # the network can bypass F5 and connect to shared-gw directly.
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: istio-gateway-leaf-tls
      allowedRoutes:
        namespaces:
          from: Selector
          selector:
            matchLabels:
              istio.io/dataplane-mode: ambient
```

### Step 2 — App Team Self-Service (In App Namespace `payments`)

Assuming `cert-manager` / Venafi creates `Secret/payments-venafi-tls` inside `payments`, the app team's Helm chart / RHDH Golden Path deploys three namespace-local resources:

#### A. F5 `TLSProfile` (Terminates App Leaf Cert, Re-Encrypts to Istio Gateway)

```yaml
apiVersion: cis.f5.com/v1
kind: TLSProfile
metadata:
  name: payments-tls-profile
  namespace: payments
  labels:
    f5cr: "true"
spec:
  hosts:
    - payments.corp.com
  tls:
    termination: reencrypt
    reference: secret
    clientSSL: payments-venafi-tls          # App's own Venafi TLS Secret in `payments`
    serverSSL: istio-gw-ca-secret           # CA bundle trusting `istio-gateway-leaf-tls` (or BIG-IP /Common/serverssl profile)
```

#### B. F5 `VirtualServer` (Binds Hostname on F5 VIP → Forwards Cross-Namespace to `shared-gw-istio`)

```yaml
apiVersion: cis.f5.com/v1
kind: VirtualServer
metadata:
  name: payments-vs
  namespace: payments
  labels:
    f5cr: "true"
spec:
  host: payments.corp.com
  # `hostGroup` shares one F5 VIP across multiple app VirtualServers via SNI/Host policy.
  # Omit `hostGroup` and set `ipamLabel` if each app receives its own dedicated VIP.
  hostGroup: shared-mesh-ingress
  virtualServerAddress: "10.50.10.20"
  tlsProfileName: payments-tls-profile
  httpTraffic: redirect
  pools:
    - path: /
      service: shared-gw-istio
      serviceNamespace: gw-ingress          # Routes directly to the central Istio Gateway Service
      servicePort: 443
```

#### C. Gateway API `HTTPRoute` (Routes Inside the `STRICT` Ambient Mesh)

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: payments-route
  namespace: payments
spec:
  parentRefs:
    - name: shared-gw
      namespace: gw-ingress
  hostnames:
    - payments.corp.com
  rules:
    - backendRefs:
        - name: payments-svc
          port: 8080
```

### F5 CIS Prerequisites Checklist

1. **Custom Resource mode:** F5 CIS runs with `--custom-resource-mode=true`.
2. **Namespace scope:** CIS watches both the tenant app namespaces (e.g., via `--namespace-label` matching mesh namespaces) and `gw-ingress` so `serviceNamespace: gw-ingress` resolves `shared-gw-istio` endpoints.
3. **Pool member mode:** Match `shared-gw-istio` Service type to CIS networking mode (`ClusterIP` when CIS uses OVN-Kubernetes / BGP / VXLAN pod routing; `NodePort` when CIS runs in NodePort mode).

---

## Option 2: Gateway API `ListenerSet` / `XListenerSet` *(Cloud-Native Gateway API Pattern)*

Kubernetes Gateway API introduced **`XListenerSet`** (`gateway.networking.x-k8s.io/v1alpha1` in Gateway API v1.3–v1.4) and graduated it to **`ListenerSet`** (`gateway.networking.k8s.io/v1` in Gateway API v1.5) to decentralize HTTPS listener and TLS certificate ownership without external load-balancer CRDs.

### Mental Model (Classic OpenShift `Route` Split in Half)

In classic OpenShift, a single `Route` object bundled both the **HTTPS front door** (`host` + `tls` cert) and **HTTP path/weight routing** (`path`, `to: Service`, `alternateBackends`). Gateway API splits those two concerns cleanly while keeping your standard Kubernetes `Service`:

| Classic OpenShift Object | Gateway API Equivalent | Owner | Responsibility |
|---|---|---|---|
| OpenShift Router (`IngressController`) | **`Gateway`** (`gw-ingress`) | Platform Team | Shared Envoy proxy fleet & port binding |
| Top half of OpenShift `Route` (`host` + `tls`) | **`ListenerSet`** (`payments` ns) | App Team | Claims `payments.apps...` and terminates TLS using local `Secret` |
| Bottom half of OpenShift `Route` (`path`, weights) | **`HTTPRoute`** (`payments` ns) | App Team | L7 routing (`/api`, headers, canary splits) to backend `Service`s |
| Kubernetes `Service` (`ClusterIP`) | **Kubernetes `Service`** (`payments` ns) | App Team | Backend pod selector (`payments-svc:8080`) |

### Step 1 — Platform Team Setup (One-Time in `gw-ingress`)

Platform creates `shared-gw` once with `spec.allowedListeners` permitting ambient-labeled namespaces to attach `ListenerSet`s:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: shared-gw
  namespace: gw-ingress
spec:
  gatewayClassName: istio
  allowedListeners:
    namespaces:
      from: Selector
      selector:
        matchLabels:
          istio.io/dataplane-mode: ambient
  listeners:
    - name: default-http
      port: 80
      protocol: HTTP
```

### Step 2 — App Team Self-Service (In App Namespace `payments`)

#### A. `ListenerSet` (Attaches App Hostname + Local Venafi Cert to `shared-gw`)

Because `ListenerSet` and `payments-venafi-tls` live in the **same namespace**, no cross-namespace `ReferenceGrant` is required:

```yaml
# gateway.networking.k8s.io/v1 (ListenerSet) in Gateway API v1.5+
# gateway.networking.x-k8s.io/v1alpha1 (XListenerSet) in Gateway API v1.3–v1.4
apiVersion: gateway.networking.k8s.io/v1
kind: ListenerSet
metadata:
  name: payments-listener
  namespace: payments
spec:
  parentRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: shared-gw
    namespace: gw-ingress
  listeners:
    - name: https
      port: 443
      protocol: HTTPS
      hostname: payments.apps.example.com
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: payments-venafi-tls
```

#### B. `HTTPRoute` (Attaches Routing Rules to the Team's `ListenerSet`)

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: payments-route
  namespace: payments
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: ListenerSet
      name: payments-listener
      sectionName: https
  rules:
    - backendRefs:
        - name: payments-svc
          port: 8080
```

*(If ingress enters via OpenShift's HAProxy Router rather than a direct L4 LB VIP, pair with a `passthrough` OpenShift `Route` for `payments.apps.example.com` targeting `shared-gw-istio`.)*

### OpenShift Version Availability Note

* **OpenShift 4.20 (ROSA & On-Prem):** Ships **Gateway API `v1.2.1` (`standard` channel)** managed by `openshift-ingress-operator`, which predates `allowedListeners` and `ListenerSet`. Even though OSSM 3.4 (`istiod 1.30.x`) includes controller support, **do not manually overwrite OpenShift's built-in `gateways.gateway.networking.k8s.io` CRD**, as the Cluster Ingress Operator reconciles it and manual modification is unsupported.
* **Check if a cluster upgrade has enabled `ListenerSet`:**
  ```bash
  oc get crd | grep -i listenerset
  oc explain gateway.spec.allowedListeners
  ```
* **Until OpenShift bundles Gateway API v1.5+:**
  * On clusters **with F5 CIS Operator**, use **Option 1** above.
  * On ROSA / clusters **without F5 CIS**, use the GitOps `hosts:` catalogue pattern in [`charts/gateway-cert-lab`](../gateway-cert-lab/README.md) (or one `Gateway` per team namespace).
