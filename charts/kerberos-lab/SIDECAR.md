# Negotiate bridge sidecar — how it works and what it needs

**Lab / spike only.** This is not a supported RHDH feature. Native Hub proxy auth remains **Basic** only ([PROXY-AUTH.md](../developer-hub/PROXY-AUTH.md)). This document describes the custom pattern we proved in-cluster: Hub talks to a **localhost Squid sidecar** with **no proxy auth**; the sidecar speaks **Kerberos Negotiate** to a corporate-style forward proxy.

Published image (amd64): `ghcr.io/rmallam-rhdh/kerberos-lab-bridge-ubi:0.1.0`  
Source: `charts/kerberos-lab/images/bridge-ubi/` (base `registry.redhat.io/rhel9/squid` + `krb5-workstation`).

---

## 1. End-to-end flow

```text
┌──────────────────────── Hub pod (e.g. rhdh-kerberos) ────────────────────────┐
│                                                                              │
│  backstage-backend                                                           │
│    NODE_OPTIONS=… --use-env-proxy                                            │
│    HTTP_PROXY / HTTPS_PROXY = http://127.0.0.1:3128   ← no userinfo         │
│         │                                                                    │
│         │  cleartext HTTP CONNECT / GET to localhost                         │
│         ▼                                                                    │
│  kerberos-bridge  (container, same network namespace)                        │
│    Squid listen :3128, http_access allow all (localhost-only trust)          │
│    cache_peer … parent … login=NEGOTIATE                                     │
│    kinit -kt /keytabs/bridge-client.keytab  <client-principal>               │
│         │                                                                    │
└─────────┼────────────────────────────────────────────────────────────────────┘
          │  TCP to corporate proxy; Proxy-Authorization: Negotiate <SPNEGO>
          ▼
   corporate-proxy (or customer proxy)
     requires Negotiate; service principal typically HTTP/<proxy-fqdn>@REALM
          │
          ▼
   allow-listed HTTPS destinations (Jira, example.com, …)

   KDC (lab MIT / customer AD)
     issues TGTs for the client principal; proxy validates tickets for its SPN
```

| Hop | Auth | Who authenticates |
|---|---|---|
| Hub → sidecar (`127.0.0.1:3128`) | **None** | Trust is “same pod / localhost only” |
| Sidecar → corporate proxy | **Negotiate (Kerberos)** | Sidecar, via Squid `login=NEGOTIATE` + keytab |
| Tunnel → SaaS | SaaS credential (Jira token, ServiceNow Basic, …) | Plugin / Hub, inside TLS after `CONNECT` |

Hub never sees Kerberos. Plugins keep calling `fetch`; Node’s `EnvHttpProxyAgent` only knows `HTTP(S)_PROXY`.

---

## 2. Why a sidecar (not a separate bridge Deployment)

| Sidecar | Separate bridge Service |
|---|---|
| Hub uses `http://127.0.0.1:3128` — no cross-namespace DNS for the no-auth listener | Hub uses `http://bridge.<ns>.svc:3128` |
| No-auth Squid never exposed as a cluster Service | Must NetworkPolicy the no-auth listen hard (any pod that can reach it is an open proxy) |
| Keytab Secret mounts on the Hub pod | Keytab on a shared PVC or separate Secret + affinity to KDC |
| One pod lifecycle with Hub | Independent scale / failure domain |

Lab default (`values-deploy.yaml`): standalone `bridge.enabled: false`. Corporate NetworkPolicy allows ingress from the Hub namespace (sidecar pods), not only from a `bridge` pod.

---

## 3. Sidecar container specification

Rendered by the Hub chart when `kerberosBridgeSidecar.enabled: true` (`templates/backstage.yaml` → Backstage CR `deployment.patch`).

### 3.1 Identity

| Field | Lab value |
|---|---|
| Container name | `kerberos-bridge` |
| Image | `ghcr.io/rmallam-rhdh/kerberos-lab-bridge-ubi:0.1.0` (or cluster IS tag) |
| User | Non-root; **do not** fix `runAsUser: 1001` under OpenShift `restricted-v2` (UID must fall in the namespace range). Image `USER 1001` is overridden by the SCC. |
| Capabilities | `drop: [ALL]`, `allowPrivilegeEscalation: false`, `seccompProfile: RuntimeDefault` |

### 3.2 Listen port (Hub-facing)

| Field | Requirement |
|---|---|
| `containerPort` | `3128` (name `proxy`) |
| Squid `http_port` | Same port; must match Hub `HTTP_PROXY` |
| Client auth on listen | **None** (`http_access allow all`). Safe only because traffic is localhost inside the pod. |
| Readiness | TCP on `proxy` (Squid up after `kinit` succeeds) |

### 3.3 Volume: client keytab

| Field | Requirement |
|---|---|
| Volume | Secret (lab: `kerberos-bridge-keytab`) |
| Mount | `/keytabs` read-only |
| File | `/keytabs/bridge-client.keytab` |
| Mode | World-readable enough for the random SCC UID (`defaultMode: 0444`) |
| Sync | Lab: `scripts/sync-bridge-keytab-secret.sh` copies from KDC PVC into the Hub namespace |

Without this file the entrypoint exits: Squid never listens → readiness fails.

### 3.4 Environment (sidecar)

| Env | Purpose | Lab example |
|---|---|---|
| `REALM` | Kerberos realm | `LAB.LOCAL` |
| `KDC_HOSTNAME` | Host for `kinit` / `krb5.conf` KDC | `kdc.kerberos-lab.svc.cluster.local` |
| `CORPORATE_PROXY_HOSTNAME` | Squid `cache_peer` parent host | `corporate-proxy.kerberos-lab.svc.cluster.local` |
| `CORPORATE_PROXY_PORT` | Parent listen port | `3128` |
| `BRIDGE_CLIENT_PRINCIPAL` | Principal in the keytab used as Negotiate **client** | `rhdh-bridge@LAB.LOCAL` |
| `KRB5_KTNAME` | Keytab path | `/keytabs/bridge-client.keytab` |
| `HOME` | Writable home for credential cache | `/tmp` |

Helm keys live under `kerberosBridgeSidecar.*` in `charts/developer-hub/values.yaml` / `values-kerberos-lab.yaml`.

### 3.5 Squid behaviour (parent / corporate hop)

From `images/bridge-ubi/squid.conf.template`:

```text
http_port 3128
http_access allow all
cache_peer <CORP_HOST> parent <CORP_PORT> 0 no-query default login=NEGOTIATE
never_direct allow all
cache deny all
```

| Directive | Meaning |
|---|---|
| `login=NEGOTIATE` | Squid obtains a service ticket and sends `Proxy-Authorization: Negotiate …` to the parent |
| `never_direct allow all` | Every request goes to the parent (no direct Internet from the sidecar) |
| `cache deny all` | Forward-only; no content cache |

Entrypoint (`entrypoint.sh`):

1. Write `/tmp/krb5.conf` (no DNS discovery — explicit KDC host).
2. `kinit -kt` with retries (sidecar may start before KDC).
3. Background ticket refresh every 6h.
4. `squid -N` with the rendered config.

---

## 4. What the sidecar needs to talk to the corporate proxy

These are the **minimum** dependencies for Negotiate to the parent. Lab names are examples; a customer AD + proxy must supply the same *kinds* of objects.

### 4.1 Kerberos client identity (sidecar side)

| Requirement | Detail |
|---|---|
| Client principal | User (or service) principal allowed to authenticate **to** the proxy as a client — lab: `rhdh-bridge@LAB.LOCAL` |
| Keytab | Keytab for that principal only (not the proxy’s server keytab) |
| Reachable KDC | TCP/UDP 88 (lab) from the Hub pod/network to the KDC |
| Clock skew | Normal Kerberos tolerance (cluster NTP) |
| Ticket lifetime | Entrypoint renews via periodic `kinit`; align with realm policy |

### 4.2 Corporate proxy (server side)

| Requirement | Detail |
|---|---|
| Negotiate enabled | Proxy must challenge with Negotiate / accept SPNEGO (lab Squid: `auth_param negotiate …`) |
| Service principal (SPN) | Typically `HTTP/<proxy-fqdn>@REALM` matching the hostname the **sidecar dials** — lab: `HTTP/corporate-proxy.kerberos-lab.svc.cluster.local@LAB.LOCAL` |
| Server keytab on proxy | Proxy process must have that SPN’s keys (lab: `corporate.keytab`) |
| Allow list | Destinations Hub will `CONNECT` to (SaaS hosts) |
| Network path | Hub namespace → proxy host:port (lab NetworkPolicy `corporate-proxy-ingress` allows `rhdh-kerberos`) |

If the FQDN the sidecar uses does not match the SPN host part, Negotiate fails even with a valid client ticket.

### 4.3 Mapping to a customer environment

| Lab | Customer analogue |
|---|---|
| MIT KDC in `kerberos-lab` | Active Directory (or other KDC) |
| `rhdh-bridge@LAB.LOCAL` + keytab Secret | App account / gMSA / keytab issued by IAM |
| `corporate-proxy` Squid + Negotiate | Existing corporate forward proxy (Blue Coat, Squid, etc.) with Kerberos |
| `HTTP/<svc.cluster.local>@REALM` | `HTTP/<proxy.customer.example>@CUSTOMER.REALM` as registered in AD |
| Allow list ConfigMap | Proxy policy for SaaS egress |
| NetworkPolicy from Hub ns | Firewall / NSG / NetworkPolicy to the proxy VIP |

Still required on Hub: Basic is **not** used on the corporate hop; SaaS credentials stay in Hub Secrets as today.

---

## 5. What the Hub container needs (consumer of the sidecar)

| Setting | Value | Where |
|---|---|---|
| `HTTP_PROXY` | `http://127.0.0.1:3128` | Hub Secret (lab: `rhdh-kerberos-secrets`) — **no** `user:pass@` |
| `HTTPS_PROXY` | Same URL | Same Secret |
| `NO_PROXY` | In-cluster + registries as usual; **omit** SaaS hosts that must exercise Negotiate | Same Secret |
| `NODE_OPTIONS` | `--no-node-snapshot --use-env-proxy` | Backstage `extraEnvs` when `httpProxy.enabled` |
| Plugin-install init | Stay **off** the Hub proxy (`httpProxy.initContainer: ""`) | Chart default |

Example Secret: `examples/rhdh-kerberos-secrets.example.yaml`.

---

## 6. Helm / chart knobs

**Hub** (`charts/developer-hub`):

```yaml
httpProxy:
  enabled: true
  nodeOptions: "--no-node-snapshot --use-env-proxy"

kerberosBridgeSidecar:
  enabled: true
  image: ghcr.io/rmallam-rhdh/kerberos-lab-bridge-ubi:0.1.0   # or cluster IS
  keytabSecret: kerberos-bridge-keytab
  port: 3128
  realm: LAB.LOCAL
  kdcHostname: kdc.kerberos-lab.svc.cluster.local
  corporateProxyHostname: corporate-proxy.kerberos-lab.svc.cluster.local
  corporateProxyPort: "3128"
  clientPrincipal: rhdh-bridge@LAB.LOCAL
```

**Lab** (`charts/kerberos-lab`):

```yaml
bridge:
  enabled: false    # standalone Deployment off when using sidecar
networkPolicy:
  allowFromNamespaces:
    - rhdh-kerberos  # Hub pods (sidecar) may reach corporate-proxy
```

---

## 7. Operational checklist

1. KDC + corporate-proxy Ready; client keytab exists on KDC PVC.
2. `sync-bridge-keytab-secret.sh` → Secret in Hub namespace; image pullable (same-ns tag or `system:image-puller`).
3. Hub Secret proxy URLs point at `127.0.0.1:3128`.
4. Hub pod shows containers including `kerberos-bridge`; bridge readiness TCP :3128.
5. Smoke from Hub:

```bash
oc -n rhdh-kerberos exec deploy/backstage-developer-hub-kerberos -c backstage-backend -- \
  sh -c 'echo "$HTTPS_PROXY"; node --use-env-proxy -e "fetch(\"https://example.com\").then(r=>console.log(r.status))"'
```

Expect `http://127.0.0.1:3128` and HTTP **200** for an allow-listed host.

### Failure modes (sidecar ↔ corporate)

| Symptom | Likely cause |
|---|---|
| Sidecar not Ready; logs `keytab missing` | Secret not mounted / wrong key name |
| Sidecar loops `waiting for KDC` | Network to KDC, wrong `KDC_HOSTNAME` / realm |
| `kinit` OK but Hub gets 407/502 via proxy | SPN mismatch, proxy Negotiate misconfig, allow-list deny |
| Hub `ENOTFOUND bridge.…` | Still pointing at old standalone Service URL — switch Secret to localhost |
| Pod `FailedCreate` / SCC `runAsUser: 1001` | Remove fixed UID; use restricted-v2 range |

---

## 8. Security notes (lab honesty)

- Localhost Squid has **no** client auth by design. Do not expose that listen on a Service/Route.
- The keytab is as powerful as the client principal; RBAC the Secret; prefer short-lived or rotated keys in a real design.
- This does not replace customer AD trust design, constrained delegation rules, or proxy compliance review.
- Prefer Basic on the corporate proxy when available — supported path for Hub without a custom sidecar.

---

## 9. Related files

| Path | Role |
|---|---|
| `images/bridge-ubi/` | UBI/RHEL 9 Squid + entrypoint |
| `scripts/sync-bridge-keytab-secret.sh` | Keytab Secret + image tag into Hub ns |
| `../developer-hub/templates/backstage.yaml` | Sidecar patch on Backstage CR |
| `../developer-hub/values-kerberos-lab.yaml` | Lab Hub overlay enabling sidecar |
| `../developer-hub/PROXY-AUTH.md` | Supported Basic story + pointer here |
| `README.md` | Deploy / smoke steps |
