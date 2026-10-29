# NTLM bridge sidecar (cntlm) — how it works and what it needs

**Lab / spike only.** This is not a supported RHDH feature. Native Hub proxy auth remains **Basic** only ([PROXY-AUTH.md](../developer-hub/PROXY-AUTH.md)). This document describes the **NTLM** sibling of [SIDECAR.md](SIDECAR.md): Hub talks to a **localhost cntlm sidecar** with **no proxy auth**; the sidecar speaks **NTLM** to a corporate-style forward proxy.

Negotiate (Kerberos) sibling: [SIDECAR.md](SIDECAR.md). Customer-share PDF source: [`.share/SIDECAR-NTLM-customer.md`](../../.share/SIDECAR-NTLM-customer.md).

Published lab image (amd64): Ubuntu `kerberos-lab-bridge` with **cntlm** — e.g. cluster tag `…/kerberos-lab-bridge:0.2.0`.  
Source: `charts/kerberos-lab/images/bridge/` (`PROXY_AUTH_MODE=ntlm`).

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
│  cntlm  (container; PROXY_AUTH_MODE=ntlm)                                    │
│    Listen 127.0.0.1:3128                                                     │
│    NTLM_USERNAME / NTLM_PASSWORD / NTLM_DOMAIN from Secret                   │
│    Proxy CORPORATE_PROXY_HOSTNAME:PORT                                       │
│         │                                                                    │
└─────────┼────────────────────────────────────────────────────────────────────┘
          │  NTLM Type1 → Type2 → Type3 on parent hop
          │  Proxy-Authorization: NTLM <base64>
          ▼
   corporate-proxy (or customer proxy)
     requires NTLM; lab uses Squid ntlm_fake_auth
          │
          ▼
   allow-listed HTTPS destinations
```

| Hop | Auth | Who authenticates |
|---|---|---|
| Hub → sidecar (`127.0.0.1:3128`) | **None** | Trust is “same pod / localhost only” |
| Sidecar → corporate proxy | **NTLM** | Sidecar via **cntlm** + Secret |
| Tunnel → SaaS | SaaS credential | Plugin / Hub, inside TLS after `CONNECT` |

Hub never sees NTLM. Plugins keep calling `fetch`; Node’s `EnvHttpProxyAgent` only knows `HTTP(S)_PROXY`.

---

## 2. How cntlm communicates with NTLM

```text
Hub → cntlm (no auth) → corporate parent (NTLM challenge / response)
```

1. Hub issues `CONNECT` (or GET) to `127.0.0.1:3128` with **no** `Proxy-Authorization`.
2. cntlm opens a connection to the corporate parent **without** credentials.
3. Parent answers **407** + `Proxy-Authenticate: NTLM`.
4. cntlm sends **Type 1** (negotiate), receives **Type 2** (challenge), sends **Type 3** (authenticate) using Username/Password/Domain.
5. On success the parent returns **200 Connection established**; Hub’s TLS continues through the tunnel.

Lab cntlm template (`images/bridge/cntlm.conf.template`) uses **`Auth NTLM`** because Squid `ntlm_fake_auth` does not supply target-info for NTLMv2. Real AD parents usually need **`Auth NTLMv2`**.

---

## 3. Why a sidecar (not a separate bridge Deployment)

Same rationale as Negotiate ([SIDECAR.md](SIDECAR.md) §2): loopback no-auth listen must not become a cluster Service. Lab NTLM overlay can enable standalone bridge (`BRIDGE_LISTEN_ADDR=0.0.0.0`) for clusters **without** Hub — NetworkPolicy still gates peers. Prefer sidecar when Hub exists (`values-kerberos-ntlm-lab.yaml` + `bridge.enabled: false`).

---

## 4. Sidecar container specification

Rendered when `kerberosBridgeSidecar.enabled: true` and `proxyAuthMode: ntlm`.

### 4.1 Identity / listen / probes

Container name **`cntlm`** (Negotiate mode keeps `kerberos-bridge`), port **3128**, loopback listen, exec `/dev/tcp/127.0.0.1/3128` probes — see Negotiate doc. Image must include the **cntlm** binary (Ubuntu bridge), not UBI Squid-only.

### 4.2 Secret (not keytab)

| Field | Lab value |
|---|---|
| Secret | `kerberos-bridge-ntlm` |
| Keys | `username`, `password`, `domain` |
| Env | `NTLM_USERNAME` / `NTLM_PASSWORD` / `NTLM_DOMAIN` |
| Keytab volume | **omitted** in NTLM mode |

### 4.3 Environment

| Env | Lab example |
|---|---|
| `PROXY_AUTH_MODE` | `ntlm` |
| `CORPORATE_PROXY_HOSTNAME` | `corporate-proxy.kerberos-lab.svc.cluster.local` |
| `CORPORATE_PROXY_PORT` | `3128` |
| `NTLM_*` | from Secret (`labntlm` / `labntlm-pass` / `LAB` in lab) |

### 4.4 Entrypoint

`images/bridge/entrypoint.sh` → `run_ntlm`: render cntlm.conf → `cntlm -f -c /tmp/cntlm.conf`.

---

## 5. Hub consumer settings

Identical to Negotiate: `HTTP(S)_PROXY=http://127.0.0.1:3128` with **no** userinfo (`examples/rhdh-kerberos-secrets.example.yaml`). NTLM lives only in the sidecar Secret.

---

## 6. Helm knobs

```yaml
# Hub
kerberosBridgeSidecar:
  enabled: true
  proxyAuthMode: ntlm
  ntlmSecret: kerberos-bridge-ntlm
  image: image-registry.openshift-image-registry.svc:5000/rhdh-kerberos/kerberos-lab-bridge:0.2.0
  corporateProxyHostname: corporate-proxy.kerberos-lab.svc.cluster.local
  corporateProxyPort: "3128"

# Lab parent
corporateProxy:
  authMode: ntlm
```

Overlays: `values-ntlm-lab.yaml`, `values-kerberos-ntlm-lab.yaml`.

---

## 7. Smoke / failure modes

| Test | Expect |
|---|---|
| `scripts/smoke-ntlm-podman.sh` | Corporate **407** + `Proxy-Authenticate: NTLM`; via bridge **200** |
| `scripts/smoke-ntlm-cluster.sh` | Same on-cluster via Services |

| Symptom | Likely cause |
|---|---|
| `Cannot do NTLMv2` | Lab fake helper — use `Auth NTLM` |
| Sidecar Ready, Hub 407 | Bad credentials / domain |
| Exec format error on OCP | Image built arm64 — rebuild `PLATFORM=linux/amd64` |

---

## 8. Security notes

- cntlm has **no** client auth on listen → **must** bind `127.0.0.1` in the Hub sidecar.
- Password Secret is as powerful as the proxy account; RBAC + rotate.
- Prefer **Basic** on the corporate proxy when available (supported Hub path).
- Dual-mode design notes: `idp-platform-docs/proxy/kerberos-ntlm-dual-mode.md`.

---

## 9. Related files

| Path | Role |
|---|---|
| `images/bridge/` | Ubuntu + cntlm |
| `images/corporate-proxy/squid.conf.ntlm.template` | Lab NTLM parent |
| `../developer-hub/templates/backstage.yaml` | Sidecar patch (`proxyAuthMode`) |
| `SIDECAR.md` | Negotiate sibling |
| `.share/SIDECAR-NTLM-customer.md` | Customer-facing NTLM doc (PDF source) |
