# RHDH architecture: active-active vs active-passive

How to run Red Hat Developer Hub for high availability inside one OpenShift cluster, and how that differs from a second-site / DR (active-passive) layout. Aligns with Red Hat’s HA guidance: scale **stateless Hub backends**, put **HA on PostgreSQL**, optional **Redis** for multi-replica cache.

This is a planning document for the IDP platform GitOps lab (`charts/developer-hub`, `charts/cnpg`, `charts/cnpg-dr`). It does not change live replicas by itself.

## What RHDH actually is

| Layer | Nature | Implication |
|---|---|---|
| Hub backend (Backstage) | **Stateless** when sessions and catalog live in PostgreSQL | Safe to run **N > 1** pods behind one Route |
| PostgreSQL | **Stateful**, single writer (primary + replicas) | HA is primary/standby failover — **not** multi-writer active-active |
| Software Catalog sources | External (Git, LDAP, SCM, …) | Many catalog rows can be rebuilt from source after restore |
| Plugins / SaaS | Outbound from Hub | Proxy, IdP, and tool availability dominate UX during an outage |

Red Hat: run **at least two** backend instances for HA; use the platform load balancer (OpenShift Route); **disable sticky sessions**; put PostgreSQL on HA; use Redis (or equivalent) when multiple backends share cache — the default in-memory cache is for single-instance only.

References:

- [Achieve high availability with database and cache layers](https://docs.redhat.com/en/documentation/red_hat_developer_hub/1.8/html/about_red_hat_developer_hub/con-achieve-high-availability-with-database-and-cache-layer_about-rhdh)
- [Configuring high availability in RHDH](https://docs.redhat.com/en/documentation/red_hat_developer_hub/1.5/html/configuring_red_hat_developer_hub/highavailability) (`replicas` > 1 on the Backstage CR / Helm)

---

## Pattern A — Active-active (same cluster)

**Meaning:** Several Hub pods all take traffic at once. One URL. One Postgres. Failover is “pod dies, Route stops sending it work.”

```text
                 ┌─────────────────────────────┐
  Users ───────► │ OpenShift Route / LB        │
                 │ (no session affinity)       │
                 └────────────┬────────────────┘
              ┌───────────────┼───────────────┐
              ▼               ▼               ▼
         Hub pod 1       Hub pod 2       Hub pod N
         (stateless)     (stateless)     (stateless)
              │               │               │
              └───────────────┼───────────────┘
                              ▼
                    PostgreSQL (CNPG)
                    primary + standbys
                              │
                    optional Redis cache
```

### How to configure (this chart)

| Knob | Where | Notes |
|---|---|---|
| Hub replicas | `instance.replicas` → Backstage `spec.deployment.patch` | Set **≥ 2** for active-active app tier |
| Postgres instances | `charts/cnpg` Cluster | Lab uses multiple instances (primary + replicas) |
| Session affinity | Route / Ingress | Keep **off** when DB-backed sessions are used |
| Shared cache | Redis (if introduced) | Required for consistent cache across replicas; not in the minimal lab chart today |
| Secrets / config | One `rhdh` namespace | All replicas share the same app-config and Secret |

### What active-active protects

- Hub pod crash, node drain, rolling upgrade of the Deployment  
- Brief compute blips on a single worker  

### What it does **not** protect

- Whole OpenShift cluster / AZ / region loss  
- Postgres cluster loss (unless CNPG / storage / backups survive)  
- IdP (Entra) or corporate proxy outage  
- Misconfiguration that breaks all replicas equally  

### Lab vs production

| Lab today (typical) | Production active-active |
|---|---|
| Often `replicas: 1` in deploy overlay | `replicas: 2` (or more) |
| CNPG multi-instance in `rhdh` | Same + anti-affinity, backup, monitored failover |
| No Redis | Add Redis (or accept colder cache / single-replica cache semantics) |

---

## Pattern B — Active-passive (second site / DR)

**Meaning:** One **active** Hub (+ its Postgres) serves users. A **passive** site (second cluster or second CNPG topology) is warm or cold and takes over after failover. Users usually get a **DNS / Global LB cutover**, not two live Hubs writing the same DB.

```text
  Active site                         Passive site
  ───────────                         ────────────
  Route ──► Hub (N pods)              Hub install ready (scaled to 0 or N)
                 │                              │
                 ▼                              ▼
            CNPG primary                   CNPG replica cluster
            (+ standbys)                   (streaming / restore from backup)
                 │                              ▲
                 └──── WAL / backup ────────────┘

  Cutover: DNS or GSLB → passive Route; promote DB; scale Hub; re-point secrets
```

### Recommended roles

| Component | Active site | Passive site |
|---|---|---|
| Hub | Serving traffic (`replicas` ≥ 1, prefer ≥ 2 locally) | Installed via GitOps; scaled down **or** up but not advertised |
| Postgres | CNPG primary cluster (`cnpg`) | Replica / restore target (`cnpg-dr` style) — **read replica or backup restore**, not a second writer for the same Hub |
| Secrets | Vault / ESO live | Same paths available on DR cluster |
| IdP / DNS | Entra redirect URI includes active URL | Update redirect / DNS on cutover (or use a stable vanity host) |

This lab already sketches a **second Postgres** path (`cnpg-dr` / `rhdh-pg-dr`). That is **database DR**, not a second live Hub. Do not point two active Hubs at two writable primaries without a deliberate multi-primary design (unsupported / out of scope for standard RHDH).

### Cutover checklist (active → passive)

1. Stop or fence writers on the failed site (avoid split-brain).  
2. Promote or restore Postgres on the passive site; verify connectivity.  
3. Point Hub on the passive site at that DB Secret; scale Hub up.  
4. Switch DNS / vanity host to the passive Route.  
5. Ensure Entra (and any OAuth apps) allow the passive Hub callback URL.  
6. Re-run catalog providers / confirm plugins reach SaaS (proxy/`NO_PROXY`).  
7. Validate login, catalog, scaffolder, Kubernetes/Topology with a break-glass plan if IdP is also impacted.

### RPO / RTO (set with the customer)

| Tier | Typical RPO | Typical RTO | Mechanism |
|---|---|---|---|
| In-cluster Hub HA only | ~0 for app pods | Seconds–minutes | Replicas + Route |
| CNPG failover same cluster | Seconds–low minutes (sync/async) | Minutes | Operator promote standby |
| Cross-cluster DR | Backup interval / WAL lag | Tens of minutes–hours | Promote `cnpg-dr`, DNS, Hub scale-up |

---

## Side-by-side

| | **Active-active (one cluster)** | **Active-passive (two sites)** |
|---|---|---|
| User URL | One | One (moves on cutover) or sticky vanity + DNS |
| Hub pods | All serving | Only active serving |
| Postgres | One HA cluster | Active primary + DR replica/backup |
| Failover | Automatic (k8s) | Manual or orchestrated promote + DNS |
| Complexity | Low | Higher (GitOps on two clusters, secrets, IdP URLs) |
| Cost | Extra Hub pods + DB replicas | Second cluster / DR DB |
| Split-brain risk | Low | Real if both Hubs write without fencing |

**Recommendation for most enterprise IDP rollouts**

1. **Always:** active-active Hub replicas **and** HA Postgres **in the primary cluster**.  
2. **Add:** active-passive **DR** (second cluster or at least `cnpg-dr` + documented cutover) if the customer’s RTO requires surviving cluster loss.  
3. **Avoid:** two “active” Hubs in two regions both writing independent Postgres copies and both advertised — that is not standard RHDH HA.

---

## Identity and break-glass (related)

HA of Hub pods does not replace IdP availability.

- Primary login: Entra (or customer IdP).  
- Break-glass: second IdP (e.g. Keycloak with local admins) or tightly controlled Guest — see auth discussion; RHDH has **no** production htpasswd local provider.  
- On DR cutover, break-glass must work on the **passive** Hub URL as well.

---

## Decision guide

| Customer need | Choose |
|---|---|
| Survive Hub pod / node failure | Active-active replicas (≥ 2) + CNPG HA |
| Survive Postgres pod failure | CNPG multi-instance + backup |
| Survive whole cluster / region | Active-passive DR + DNS + IdP redirect readiness |
| Lowest cost lab | `replicas: 1`, CNPG as today; document DR as stretch goal |

---

## Mapping to this GitOps repo

| Piece | Chart / app | Role in HA |
|---|---|---|
| Hub CR + config | `charts/developer-hub` / `developer-hub` | Set `instance.replicas` for active-active |
| Primary DB | `charts/cnpg` / `cnpg` | In-cluster Postgres HA |
| DR DB sketch | `cnpg-dr` / `rhdh-pg-dr` | Passive-side database — not a second live Hub |
| Mesh | Keep Hub/Postgres **off** ambient (`mesh.ambient: false`) | Avoid probe/timeout issues during scale |

---

## Out of scope / non-goals

- Multi-writer Postgres (Spock / BDR-style) for RHDH  
- Active-active Hubs in two clusters sharing one logical DB without a single primary  
- Treating catalog-only restore as full DR without scaffolder task history / plugin state review  

When in doubt: **scale Hub horizontally; HA the database; DR the site with explicit promote and DNS.**
