# Support brief: Hub + Kerberos (Negotiate) proxy

**Audience:** Product support / SE reviewing whether this pattern can be endorsed for a customer conversation.  
**Status:** Lab-proven **custom spike**. **Not** a supported RHDH product feature.

---

## One-sentence answer

Developer Hub natively authenticates to an HTTP forward proxy with **Basic only**. If the corporate proxy is **Kerberos/Negotiate-only**, Hub cannot speak Negotiate; a **custom localhost Squid sidecar** can Negotiate upstream while Hub uses `HTTP_PROXY=http://127.0.0.1:3128` with **no** proxy credentials.

---

## What is supported vs what this spike shows

| Topic | Supported product answer | This spike |
|---|---|---|
| Proxy auth from Hub/Node | **Basic** (`user:pass@proxy`) | Hub still sends **no** proxy auth (localhost) |
| Digest / NTLM / Negotiate / Kerberos from Hub | **No** | Negotiate happens **only** in the sidecar |
| Support entitlement | Basic proxy + `NODE_OPTIONS=--use-env-proxy` | Custom image + keytab + SPN design = **customer/custom engineering** |
| Prefer if customer can | Issue a Basic app account on the proxy | Use this only when Basic is impossible |

Full Basic Q&A: [`../developer-hub/PROXY-AUTH.md`](../developer-hub/PROXY-AUTH.md).  
Technical sidecar spec: [`SIDECAR.md`](SIDECAR.md).

---

## How it works (explain in three hops)

```text
1) Hub (backstage-backend)
      HTTP(S)_PROXY = http://127.0.0.1:3128
      NODE_OPTIONS includes --use-env-proxy
      Plugins call fetch → EnvHttpProxyAgent → localhost

2) Sidecar (kerberos-bridge) in the SAME pod
      Squid listens on 127.0.0.1:3128 only (no client auth)
      kinit from mounted client keytab
      cache_peer parent … login=NEGOTIATE

3) Corporate proxy (customer)
      Requires Negotiate; validates ticket for HTTP/<proxy-fqdn>@REALM
      CONNECT to allow-listed SaaS (Jira, ServiceNow, …)
```

SaaS credentials (Jira token, ServiceNow user/password) stay **inside** TLS after CONNECT. They are not proxy credentials.

---

## What the customer must provide (checklist)

Hand this list to IAM / proxy / network teams:

1. **Client principal + keytab** for an application identity allowed to authenticate *to* the proxy (not the proxy’s server keytab).
2. **Proxy FQDN and port** as seen from the Hub namespace (pod egress path).
3. **SPN** on the proxy matching that FQDN (typically `HTTP/<fqdn>@REALM`). Mismatch → Negotiate fails with a “valid” keytab.
4. **KDC reachability** from Hub pods (usually TCP/UDP 88) and acceptable clock skew.
5. **Allow list** of SaaS destinations the Hub will CONNECT to.
6. **Network path** Hub namespace → proxy (firewall / NetworkPolicy).
7. Agreement that this sidecar is **custom**, outside Hub’s supported proxy-auth matrix.

Mount contract on our side: Kubernetes Secret with key `bridge-client.keytab` → sidecar volume `/keytabs` → `HTTP_PROXY=http://127.0.0.1:3128` on Hub.

---

## Security points support should insist on

- Sidecar Squid **must** bind **loopback only**. Binding `0.0.0.0:3128` with no client auth makes the **Hub pod IP an open forward proxy**.
- Never expose the bridge as a Service/Route.
- Treat the keytab like a password (RBAC Secret / Vault; rotate with IAM).
- Prefer Basic on the corporate proxy when the customer can issue an app account.

---

## Lab proof (what we demonstrated)

| Item | Result |
|---|---|
| Image | RHEL 9 Squid + krb5 (`ghcr.io/rmallam-rhdh/kerberos-lab-bridge-ubi:0.1.0`) |
| Hub | Dedicated instance `rhdh-kerberos`, sidecar container `kerberos-bridge` |
| Proxy URL | `http://127.0.0.1:3128` (no userinfo) |
| Upstream | Lab Squid requiring Negotiate + MIT KDC |
| Smoke | `fetch("https://example.com")` → 200 via sidecar |
| GitOps | Opt-in under `argocd/apps-lab/` (not default app-of-apps) |

---

## Endorsement language (suggested)

> Developer Hub does not support Kerberos/Negotiate proxy authentication natively. Where the customer proxy requires Negotiate, a **custom unsupported** pattern is to run a Negotiate-capable forward proxy as a **localhost sidecar** and point Hub `HTTP_PROXY`/`HTTPS_PROXY` at `http://127.0.0.1:3128`. Red Hat has a **lab spike** documenting the container contract, keytab/SPN prerequisites, and failure modes. Production use requires customer ownership of the keytab, SPN alignment, network path, and operational support of the sidecar image. **Preferred supported path remains Basic auth on the corporate proxy.**

---

## Do not endorse as

- A supported RHDH configuration toggle
- A replacement for fixing Hub to speak Negotiate natively
- A turnkey AD integration (lab MIT KDC ≠ customer AD)

---

## Pointers

| Doc | Use |
|---|---|
| [SIDECAR.md](SIDECAR.md) | Spec, env, probes, failure modes |
| [README.md](README.md) | Deploy / smoke steps |
| [PROXY-AUTH.md](../developer-hub/PROXY-AUTH.md) | Supported Basic answers |
| `argocd/apps-lab/` | Opt-in Argo Applications |
