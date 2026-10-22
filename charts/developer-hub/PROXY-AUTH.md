# Hub proxy: questions for the customer, and answers we can give

Use this when the customer asks how Red Hat Developer Hub reaches SaaS through their forward proxy, or when we have to ask them what that proxy actually is.

The Hub does not have its own proxy-auth feature. On Node 24 the process uses `HTTP_PROXY`, `HTTPS_PROXY`, and `NO_PROXY`, and only after `NODE_OPTIONS` includes `--use-env-proxy`. The HTTP client is then `EnvHttpProxyAgent`. Plugins such as ServiceNow, Jira, and Dynatrace do not get a proxy username or password of their own. They call `fetch`. The process decides whether that call goes to the proxy.

The proxy credential and the SaaS credential are different. The proxy sees `Proxy-Authorization: Basic` for the Hub's proxy account. The SaaS token or password stays inside the TLS tunnel after `CONNECT`, as that plugin's own `Authorization` header.

This does not apply to Dev Spaces, the operators, or image pulls by the node. Those follow the OpenShift cluster `Proxy` object. The lab leaves the plugin-install init container off the Hub proxy, because registry pulls redirect to CDNs the proxy will refuse.

## What we can support

| Topic | Supported |
|---|---|
| Proxy authentication | Basic only. The username and password are the userinfo on the proxy URL. Node sends `Proxy-Authorization: Basic`. |
| Digest, NTLM, Negotiate, Kerberos | No. There is no setting that turns them on. |
| Client certificate to the proxy | No. The environment-variable proxy has no certificate field. |
| TLS to the proxy | Yes, if both proxy URLs use `https://` and the proxy listens with TLS. Basic auth is then inside that TLS session. The Hub must trust the proxy certificate. |
| TLS inspection | Separate from the line above. If the proxy decrypts SaaS traffic and presents its own certificate, mount that CA and set `NODE_EXTRA_CA_CERTS`. Do not use `NODE_TLS_REJECT_UNAUTHORIZED=0` as the fix. |
| One plugin only | No plugin switch. A host is proxied when it is absent from `NO_PROXY`. Everything else the process dials is proxied too, unless it is listed there. |
| Proxy URL in git | No. This lab stores `HTTP_PROXY`, `HTTPS_PROXY`, and `NO_PROXY` on Secret `rhdh-secrets` (`secrets.mode: external`). The Vault path is `rhdh/http-proxy` (and the https / no-proxy twins) only when External Secrets owns that Secret. |

`HTTP_PROXY` and `HTTPS_PROXY` are the same URL. `HTTPS_PROXY=http://proxy.example.com:8080` means "use this proxy for HTTPS targets" over a cleartext connection to the proxy. `HTTPS_PROXY=https://proxy.example.com:8443` means the connection to the proxy itself is TLS.

Percent-encode `@`, `:`, and `/` in the password. An unencoded `@` or `:` is parsed as part of the URL, and authentication fails.

`NODE_OPTIONS` is replaced, not appended. The pod already needs `--no-node-snapshot`. The value has to be `--no-node-snapshot --use-env-proxy`. Setting only `--use-env-proxy` drops the snapshot flag.

If any of the three Vault keys is missing, the whole ExternalSecret stays NotReady.

## Questions to ask

Ask these before promising a design. The answers change the Vault URL, `NO_PROXY`, and whether we can authenticate at all.

1. Is every Hub egress required to use the proxy, or only named SaaS hosts? We cannot mark a plugin. We can only list bypass hosts in `NO_PROXY`.
2. What authentication does the proxy require for an application account? We can do Basic. We cannot do Digest, NTLM, or Kerberos.
3. Is a dedicated proxy account available for the Hub, and who rotates the password?
4. Does the password contain `@`, `:`, or `/`? We percent-encode those characters.
5. Must the Hub connect to the proxy with TLS (`https://proxy:port`), or is the proxy plain HTTP on the internal network?
6. If the proxy listener is TLS, who issues the certificate, and can they give us the CA bundle to set as `NODE_EXTRA_CA_CERTS`?
7. Does the proxy intercept TLS and re-sign SaaS certificates? If it does, we need that signing CA. Disabling certificate checks is not the answer we will give.
8. What is the proxy host and port as seen from a pod in the Hub namespace? A proxy that users reach in a browser may not be the address a pod can open.
9. Can the Hub namespace egress to that address, under their NetworkPolicy?
10. Which destinations must work: ServiceNow, Jira, Dynatrace, Entra (`login.microsoftonline.com`, `graph.microsoft.com`), GitHub, and any other SaaS the plugins call? Their proxy must allow those names.
11. Do plugin image pulls (`registry.access.redhat.com`, `quay.io`, `ghcr.io`, and their CDNs) have to use the proxy? Those pulls follow redirects to hosts that will not match a short allow list. Prefer bypassing registry hosts in `NO_PROXY`.
12. What bypass list do they already use? We have to add every in-cluster name the Hub dials, including the Postgres short name (`rhdh-pg-rw`), `.svc`, the Kubernetes API, Vault, Jenkins, and the cluster apps domain. A suffix of `.svc` does not cover a short name.
13. Does the cluster `Proxy` object already inject `HTTPS_PROXY` into pods? If it does, we must not set a second, conflicting URL.
14. Will they accept the proxy password in a Kubernetes Secret and in the Hub process environment? That is how Node reads it. See the pen-test notes below.
15. Does their proxy log the username, the destination host, or the full URL? Ours logs the proxy username and the destination, not the password and not the SaaS token.

## Answers we can give

**How does the Hub log in to the proxy?**
The proxy URL in the Secret is `http://USER:PASSWORD@proxy.example.com:8080` or the `https://` form. Node sends Basic auth to the proxy. The ServiceNow (or Jira, or Dynatrace) username and password are not that header. They are inside the tunnel.

**Can we use our existing Kerberos or integrated-Windows proxy?**
No, not natively. The Hub will not send Negotiate or NTLM. **Preferred supported answer:** issue a Basic-auth application account on the proxy. **If Basic is impossible:** a **custom unsupported** localhost Negotiate sidecar can be discussed as a spike — see the support talk track and checklist in [`charts/kerberos-lab/SUPPORT-BRIEF.md`](../kerberos-lab/SUPPORT-BRIEF.md) and the technical contract in [`SIDECAR.md`](../kerberos-lab/SIDECAR.md). Do not present the sidecar as a supported RHDH feature or product toggle.

**Can the proxy hop be TLS?**
Yes. Use an `https://` proxy URL, terminate TLS on the proxy, and give the Hub the CA. Auth stays Basic. We have confirmed Node 24 accepts an `https://` proxy URL. The lab proxy listens on cleartext HTTP only, so that lab path is not a TLS proof.

**Can only ServiceNow use the proxy?**
Only by putting every other host the process dials into `NO_PROXY`, and leaving the ServiceNow domain off that list. The ServiceNow plugin has no proxy field. In the lab, the ServiceNow host produced `TCP_TUNNEL/200` in the proxy log, `github.com` was in `NO_PROXY` and did not appear there, and `example.com` was refused because it was neither bypassed nor allowed.

**Where is the password?**
Vault holds the plaintext password and the full proxy URL. Kubernetes Secret `rhdh-secrets` holds `HTTP_PROXY` and `HTTPS_PROXY` for the Hub container. The proxy stores a hash and checks Basic auth against it. The ServiceNow ConfigMap has `${SERVICENOW_USERNAME}` and `${SERVICENOW_PASSWORD}` only. Those are the SaaS account, not the proxy account. The proxy URL is not in that ConfigMap and not in git.

**Will the password show up in logs?**
It must not, and in the lab it did not, in the Hub logs or the proxy logs. The proxy access log does show the proxy username on each line. Do not turn on proxy debug that prints headers.

**What will a pen test say?**
These points are real:

- Basic auth is reversible base64. On a cleartext proxy hop, anyone who can see the packets between the Hub and the proxy sees the password.
- The password is in the Hub environment. Anyone who can read the Secret or exec the pod gets it. Base64 in a Secret is not encryption. Any code running in the Hub process uses that proxy identity automatically.
- The password also exists in Vault in plaintext, inside the proxy URL.
- A proxy hash such as apr1 is what Squid checks. It is not a reason to put the plaintext password in a ConfigMap or a log.

Tight RBAC on the Secret, a NetworkPolicy so only the Hub namespace can reach the proxy, and TLS to the proxy are the controls we can offer. They do not remove Basic auth.

**What is a proxy 403 versus a SaaS 401?**
A proxy refusal is a connection error in the Hub log, or `TCP_DENIED` in the proxy log. HTTP 401 from ServiceNow, Jira, or Dynatrace means that product rejected its own credential. The tunnel was already open.

## What breaks if we miss it

- Postgres, Vault, or the API go through the proxy because their names were left off `NO_PROXY`, and the proxy denies internal names.
- `NODE_OPTIONS` is set to only `--use-env-proxy`, and the snapshot flag is gone.
- The plugin installer is given the proxy, then fails on a registry CDN that the allow list does not contain.
- The password is not percent-encoded, so the proxy returns 407.
- The three Vault keys are not all present, so ExternalSecret does not sync and the Hub does not roll onto the proxy.
- The customer proxy is Kerberos, and we have already said the Hub will authenticate.

Deploy steps for the flag, the Vault keys, and the CA stay in [DEPLOY-RHDH-ONLY.md](DEPLOY-RHDH-ONLY.md#4-corporate-http-proxy-for-saas-calls).
