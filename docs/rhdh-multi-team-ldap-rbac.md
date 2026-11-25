# Multi-Team Catalog Isolation & LDAP RBAC in Red Hat Developer Hub (RHDH 1.10)

This guide documents the production-grade multi-team onboarding and Role-Based Access Control (RBAC) architecture implemented and verified in Red Hat Developer Hub (RHDH 1.10 / Backstage 1.49.4), answering the two core enterprise questions:

1. **Authentication & Onboarding:** How multiple application teams log in to RHDH and bind to their synced LDAP `User` and `Group` entities without manual user creation.
2. **Per-Team Read-Only (`-ro`) & Read-Write (`-rw`) Catalog Isolation:** How to restrict each team to see **only their own catalog entities** (plus shared platform `Template`, `User`, and `Group` entities) while keeping separate Read-Only and Read-Write LDAP groups per team — **without creating `2 × N` custom RBAC roles as you scale to dozens of teams**.

---

## 1. Architecture Overview (Option 1: Nested LDAP Umbrella Groups + 2 Reusable Roles)

In Backstage and RHDH, every Catalog entity (`Component`, `System`, `API`, `Resource`) has a **single** `spec.owner` field (for example, `spec.owner: group:default/team-payments`).

If a team has two separate LDAP groups — `team-payments-ro` (viewers) and `team-payments-rw` (editors) — making both groups match `spec.owner: group:default/team-payments` cleanly at scale uses **Nested LDAP Umbrella Groups** paired with **Transitive Group Ownership** (`includeTransitiveGroupOwnership: true`):

```
Enterprise 3-Level AD / OpenLDAP Hierarchy
└── RHDH-users                            <── Level 1: Top-level Portal Login & LDAP Sync Gatekeeper Group
    ├── rhdh-payments-users               <── Level 2: Team Umbrella Group (Catalog spec.owner)
    │   ├── rhdh-payments-rw              <── Level 3a: Listed in values.yaml -> teamGroups.readWrite (e.g., alice)
    │   └── rhdh-payments-ro              <── Level 3b: Listed in values.yaml -> teamGroups.readOnly  (e.g., bob)
    │
    └── rhdh-retail-users                 <── Level 2: Team Umbrella Group (Catalog spec.owner)
        ├── rhdh-retail-rw                <── Level 3a: Listed in values.yaml -> teamGroups.readWrite (e.g., carol)
        └── rhdh-retail-ro                <── Level 3b: Listed in values.yaml -> teamGroups.readOnly
```

*(Note: In our ROSA lab OpenLDAP, the Level 2 & Level 3 groups are named `team-payments` / `team-payments-rw` / `team-payments-ro` and `team-retail` / `team-retail-rw` / `team-retail-ro`.)*

### How Each of the 3 Levels Works During Team Onboarding

1. **Level 1 — `RHDH-users` (Portal Login & Sync Gatekeeper):**
   - Controls **who is synced into RHDH and allowed to log in**.
   - In a corporate directory with tens of thousands of employees, you configure `ldapOrg` with a recursive membership filter pointing at `RHDH-users` (for Active Directory: `(memberOf:1.2.840.113556.1.4.1941:=CN=RHDH-users,OU=Groups,DC=corp,DC=example,DC=com)`).
   - When a new team is onboarded, adding `rhdh-payments-users` as a nested member of `RHDH-users` automatically syncs everyone inside `rhdh-payments-ro` and `rhdh-payments-rw` into RHDH's Catalog within 5 minutes — granting them SSO login access.
2. **Level 2 — `rhdh-payments-users` (Team Umbrella Group / `spec.owner`):**
   - Controls **which Catalog items belong to the team**.
   - Every Component, System, and API owned by Payments sets `spec.owner: group:default/rhdh-payments-users`.
   - Because `includeTransitiveGroupOwnership: true` is enabled at the root of `app-config.yaml`, RHDH walks up the group tree at login so both `rhdh-payments-ro` and `rhdh-payments-rw` users inherit `group:default/rhdh-payments-users` in their token's `$ownerRefs`.
3. **Level 3 — `rhdh-payments-ro` & `rhdh-payments-rw` (Role-Specific Access):**
   - Controls **what actions each user can take** on their team's entities.
   - Added under `permission.teamGroups.readOnly` (`role:default/team-viewer`) and `permission.teamGroups.readWrite` (`role:default/team-editor`) in `values.yaml` — hot-reloaded in memory with **zero pod restarts**.

> **Two Critical Guardrails for the 3-Level Model:**
> 1. **Never set `spec.owner: group:default/rhdh-users` on team entities (and never bind `RHDH-users` to an RBAC role):** Because `includeTransitiveGroupOwnership: true` walks all ancestor groups, *every* onboarded user inherits `group:default/rhdh-users` in `$ownerRefs`. Keeping `RHDH-users` strictly for LDAP/SSO admission guarantees `payments` and `retail` stay 100% isolated from each other.
> 2. **Microsoft Entra ID "User Assignment Required" Check:** If your corporate Entra ID Enterprise App has *"Assignment required = Yes"*, verify whether your Entra ID tier expands nested groups 2 levels deep (`RHDH-users -> rhdh-payments-users -> rhdh-payments-ro`). If it only expands 1 level, either turn off *"Assignment required"* in Entra ID (RHDH's `signIn.resolvers` will still strictly block anyone not in `RHDH-users`!) or assign the team groups directly in Entra ID.

### Why This Is the Enterprise Best Practice
- **Only 2 RBAC roles ever exist in RHDH:** `role:default/team-viewer` and `role:default/team-editor`.
- **Onboarding Team #50 requires zero Casbin CSV editing:** just add the group names under `permission.teamGroups.readOnly` and `permission.teamGroups.readWrite` in `values.yaml`, and our Helm chart renders the Casbin `g, group:default/<name>, ...` bindings automatically (with **zero changes** to `rbac-conditional-policies.yaml`).
- **Clean Catalog ownership:** Every `catalog-info.yaml` simply declares `spec.owner: group:default/team-payments`.
- **Least-privilege template protection:** Conditional policies split `read` (team-owned entities **or** `Template`/`User`/`Group`) from `update`/`delete` (team-owned entities **only**), preventing `team-editor` users from deleting shared Golden Path templates.

---

## 2. How Application Teams Log In (LDAP Catalog Sync + OIDC/Entra Sign-In Resolvers)

LDAP (`ldapOrg`) is **not** an interactive login protocol in RHDH — instead, RHDH separates **Identity Hydration** (Catalog Sync) from **Interactive Authentication** (SSO):

1. **LDAP Catalog Provider (`catalog.providers.ldapOrg`):** Periodically syncs `inetOrgPerson` / `user` entries and nested `groupOfNames` / `group` hierarchies from OpenLDAP or Active Directory into the RHDH Software Catalog (`user:default/alice`, `group:default/team-payments-rw`, `group:default/team-payments`).
2. **SSO Auth Provider (`microsoft`, `oidc` / Keycloak / Ping / Okta):** Authenticates the user in the browser and uses a **Sign-In Resolver** (`emailMatchingUserEntityProfileEmail` or `preferredUsernameMatchingUserEntityName`) to match the SSO claim (`email` or `preferred_username`) to the LDAP-synced `User` entity in the Catalog.
3. **Transitive Ownership Claim Issuance (`includeTransitiveGroupOwnership: true`):** At sign-in, RHDH's `TransitiveGroupOwnershipResolver` walks `memberOf` and `childOf` relations in the Catalog and embeds **both** the direct child group (`group:default/team-payments-ro`) and the parent umbrella group (`group:default/team-payments`) into the user's signed Backstage JWT (`ent` / `$ownerRefs`).

> **Production Security Rule:** In production (`values.yaml`), **do not** set `dangerouslyAllowSignInWithoutUserInCatalog: true`. Leaving it `false` (the default) ensures that only users who exist in your synced corporate LDAP groups can log in to RHDH.

---

## 3. Step-by-Step Implementation Guide

### Step 1: Create the Nested Group Hierarchy in LDAP

In OpenLDAP (`groupOfNames`) or Active Directory, create the parent umbrella group (`cn=team-payments`) whose `member` attributes reference the `-rw` and `-ro` child group DNs.

RHDH's `backstage-plugin-catalog-backend-module-ldap-dynamic` automatically detects group DNs inside `member` and populates `spec.children` / `spec.parent` (`parentOf` / `childOf` relations) with **no extra `ldapOrg` configuration required**.

```ldif
# Child Read-Write Group (Alice)
dn: cn=team-payments-rw,ou=groups,dc=acme,dc=demo
objectClass: groupOfNames
cn: team-payments-rw
description: Payments Team Read-Write Editors
member: uid=alice,ou=people,dc=acme,dc=demo

# Child Read-Only Group (Bob)
dn: cn=team-payments-ro,ou=groups,dc=acme,dc=demo
objectClass: groupOfNames
cn: team-payments-ro
description: Payments Team Read-Only Viewers
member: uid=bob,ou=people,dc=acme,dc=demo

# Level 2: Parent Team Umbrella Group (owns Catalog Entities: spec.owner: group:default/team-payments)
dn: cn=team-payments,ou=groups,dc=acme,dc=demo
objectClass: groupOfNames
cn: team-payments
description: Payments Team Umbrella Ownership Group
member: cn=team-payments-rw,ou=groups,dc=acme,dc=demo
member: cn=team-payments-ro,ou=groups,dc=acme,dc=demo

# Level 1: Top-Level Portal Gatekeeper Group (controls who is synced into RHDH)
dn: cn=rhdh-users,ou=groups,dc=acme,dc=demo
objectClass: groupOfNames
cn: rhdh-users
description: Top-level Developer Hub Portal Access Group
member: cn=team-payments,ou=groups,dc=acme,dc=demo
member: cn=team-retail,ou=groups,dc=acme,dc=demo
```

> **Active Directory Recursive Filter (`RHDH-users` Gatekeeper):**
> In customer Active Directory environments, use AD's `LDAP_MATCHING_RULE_IN_CHAIN` OID (`1.2.840.113556.1.4.1941`) on `users.options.filter` and `groups.options.filter` so RHDH **only** syncs users and child groups nested under `CN=RHDH-users` (instead of scanning the entire company directory):
> ```yaml
> users:
>   - dn: "OU=Users,DC=corp,DC=example,DC=com"
>     options:
>       filter: "(&(objectClass=user)(objectCategory=person)(!(userAccountControl:1.2.840.113556.1.4.803:=2))(memberOf:1.2.840.113556.1.4.1941:=CN=RHDH-users,OU=Groups,DC=corp,DC=example,DC=com))"
>       paged: true
> groups:
>   - dn: "OU=Groups,DC=corp,DC=example,DC=com"
>     options:
>       filter: "(&(objectClass=group)(|(cn=RHDH-users)(memberOf:1.2.840.113556.1.4.1941:=CN=RHDH-users,OU=Groups,DC=corp,DC=example,DC=com)))"
>       paged: true
> ```

---

### Step 2: Enable `includeTransitiveGroupOwnership: true` & RBAC Files in `app-config.yaml`

> **CRITICAL RHDH 1.10 Requirement:** By default, RHDH 1.10 sets `includeTransitiveGroupOwnership` to `false` in `TransitiveGroupOwnershipResolver`. You **must** set `includeTransitiveGroupOwnership: true` at the **top level (root)** of `app-config.yaml` so users in `team-payments-ro` / `team-payments-rw` inherit `group:default/team-payments` in `$ownerRefs`!

```yaml
app:
  title: "Acme Developer Hub"
  baseUrl: "https://backstage-developer-hub-rhdh.apps.<cluster-domain>"

organization:
  name: "Acme"

# REQUIRED at root level so child LDAP groups (-ro / -rw) inherit parent group ownership!
includeTransitiveGroupOwnership: true

auth:
  environment: production
  session:
    secret: "${BACKEND_SECRET}"
  providers:
    microsoft:
      production:
        clientId: "${AZURE_CLIENT_ID}"
        clientSecret: "${AZURE_CLIENT_SECRET}"
        tenantId: "${AZURE_TENANT_ID}"
        signIn:
          resolvers:
            - resolver: emailMatchingUserEntityProfileEmail

catalog:
  providers:
    ldapOrg:
      default:
        target: "ldap://openldap.ldap.svc.cluster.local:389"
        bind:
          dn: "cn=admin,dc=acme,dc=demo"
          secret: "${LDAP_BIND_PASSWORD}"
        schedule:
          frequency: { minutes: 5 }
          timeout: { minutes: 2 }
          initialDelay: { seconds: 15 }
        users:
          - dn: "ou=people,dc=acme,dc=demo"
            options:
              filter: "(objectClass=inetOrgPerson)"
              paged: true
            map:
              rdn: uid
              name: uid
              displayName: cn
              email: mail
            set:
              metadata.namespace: default
        groups:
          - dn: "ou=groups,dc=acme,dc=demo"
            options:
              filter: "(objectClass=groupOfNames)"
              paged: true
            map:
              rdn: cn
              name: cn
              description: description
              displayName: cn
              members: member
            set:
              metadata.namespace: default

permission:
  enabled: true
  rbac:
    admin:
      # Platform admins who can inspect/manage RBAC policies
      users:
        - name: user:default/platform-admin
      # Super-users who bypass conditional restrictions across all teams
      superUsers:
        - name: user:default/platform-admin
    pluginsWithPermission:
      - catalog
      - scaffolder
      - permission
      - kubernetes
      - argocd
      - jenkins
      - sonarqube
      - techdocs
    policies-csv-file: /opt/app-root/src/rbac/rbac-policies.csv
    conditionalPoliciesFile: /opt/app-root/src/rbac/rbac-conditional-policies.yaml
    policyFileReload: true
```

> **Zero-Restart Hot Reload Architecture:**
> Do **not** mount `rbac-policies` via `spec.application.extraFiles.configMaps` on the `Backstage` CR — the RHDH Operator mounts `extraFiles` with Kubernetes `subPath` (which kubelet never updates live) and stamps `rhdh.redhat.com/ext-config-hash` (forcing a pod rollout on every edit).
> Instead, our chart mounts `rbac-policies` as a **directory volume** at `/opt/app-root/src/rbac` under `spec.deployment.patch` and sets `CHOKIDAR_USEPOLLING=true` + `CHOKIDAR_INTERVAL=5000` (required because default Linux `inotify` misses Kubernetes's atomic `..data` symlink swap). Adding a new team to `values.yaml` hot-reloads in memory within ~60 seconds with **zero pod restarts**.

---

### Step 3: Onboard Teams via `permission.teamGroups` in `values.yaml` (Zero CSV Editing)

Instead of manually writing Casbin `g, ...` CSV lines for every team, our Helm chart (`charts/developer-hub/templates/configmap-rbac.yaml`) exposes two clean YAML lists in `values.yaml`:

```yaml
permission:
  teamGroups:
    readOnly:
      - team-payments-ro
      - team-retail-ro
    readWrite:
      - team-payments-rw
      - team-retail-rw
```

Helm automatically renders those lists alongside the static `team-viewer` and `team-editor` role rules into `rbac-policies.csv` (mounted as a live-updating directory volume at `/opt/app-root/src/rbac` under `spec.deployment.patch` on the `Backstage` CR).

> **Important Gotcha:** Do **not** add unconditional `p, role:default/team-viewer, catalog-entity, read, allow` or `p, role:default/team-editor, catalog-entity, read, allow` lines in `rbac-policies.csv`. All `catalog-entity` permissions (`read`, `update`, `delete`) must come **exclusively** from `rbac-conditional-policies.yaml` so global allow rules never shadow ownership conditions.

Rendered `rbac-policies.csv`:
```csv
# Role 1: Team Viewer (Read-Only) — no entity create/delete/unregister, no template execution
p, role:default/team-viewer, catalog.location.read, read, allow
p, role:default/team-viewer, scaffolder.template.parameter.read, read, allow
p, role:default/team-viewer, scaffolder.template.step.read, read, allow
p, role:default/team-viewer, kubernetes.clusters.read, read, allow
p, role:default/team-viewer, kubernetes.resources.read, read, allow
p, role:default/team-viewer, argocd.view.read, read, allow

# Role 2: Team Editor (Read-Write) — can register components and execute Golden Path templates
p, role:default/team-editor, catalog.entity.create, create, allow
p, role:default/team-editor, catalog.location.create, create, allow
p, role:default/team-editor, catalog.location.read, read, allow
p, role:default/team-editor, catalog.location.delete, delete, allow
p, role:default/team-editor, scaffolder.template.use, use, allow
p, role:default/team-editor, scaffolder.template.parameter.read, read, allow
p, role:default/team-editor, scaffolder.template.step.read, read, allow
p, role:default/team-editor, scaffolder.action.execute, use, allow
p, role:default/team-editor, scaffolder.task.create, create, allow
p, role:default/team-editor, scaffolder.task.read, read, allow
p, role:default/team-editor, scaffolder.task.cancel, update, allow
p, role:default/team-editor, kubernetes.clusters.read, read, allow
p, role:default/team-editor, kubernetes.resources.read, read, allow
p, role:default/team-editor, argocd.view.read, read, allow

# Read-Only team groups (auto-rendered from permission.teamGroups.readOnly)
g, group:default/team-payments-ro, role:default/team-viewer
g, group:default/team-retail-ro, role:default/team-viewer
# Read-Write team groups (auto-rendered from permission.teamGroups.readWrite)
g, group:default/team-payments-rw, role:default/team-editor
g, group:default/team-retail-rw, role:default/team-editor
```

---

### Step 4: Configure `rbac-conditional-policies.yaml` (Entity Ownership Isolation)

> **RHDH 1.10 YAML Format Note:** `@backstage-community/plugin-rbac-backend`'s `YamlConditionalPoliciesFileWatcher` parses `rbac-conditional-policies.yaml` using `yaml.loadAll(...)` (**multi-document YAML separated by `---`**), **not** a top-level YAML array (`- result: ...`). Also, `catalog.entity.create` is a basic permission (configured in CSV above), so `permissionMapping` for `resourceType: catalog-entity` only accepts `[read]`, `[update]`, and `[delete]`.

```yaml
---
# 1. Team Viewer: Read own team's entities (via $ownerRefs) + shared Templates/Users/Groups
result: CONDITIONAL
roleEntityRef: role:default/team-viewer
pluginId: catalog
resourceType: catalog-entity
permissionMapping:
  - read
conditions:
  anyOf:
    - resourceType: catalog-entity
      rule: IS_ENTITY_OWNER
      params:
        claims:
          - $ownerRefs
    - resourceType: catalog-entity
      rule: IS_ENTITY_KIND
      params:
        kinds:
          - Template
          - User
          - Group
---
# 2. Team Editor (Read): Same read visibility as Team Viewer
result: CONDITIONAL
roleEntityRef: role:default/team-editor
pluginId: catalog
resourceType: catalog-entity
permissionMapping:
  - read
conditions:
  anyOf:
    - resourceType: catalog-entity
      rule: IS_ENTITY_OWNER
      params:
        claims:
          - $ownerRefs
    - resourceType: catalog-entity
      rule: IS_ENTITY_KIND
      params:
        kinds:
          - Template
          - User
          - Group
---
# 3. Team Editor (Write): Update/Refresh & Delete/Unregister ONLY on own team's entities
#    (Excludes IS_ENTITY_KIND so editors cannot delete shared Golden Path Templates!)
result: CONDITIONAL
roleEntityRef: role:default/team-editor
pluginId: catalog
resourceType: catalog-entity
permissionMapping:
  - update
  - delete
conditions:
  resourceType: catalog-entity
  rule: IS_ENTITY_OWNER
  params:
    claims:
      - $ownerRefs
```

---

### Step 5: Set `spec.owner` on Team Catalog Entities

Every microservice or system owned by a team simply sets `spec.owner` to the **parent umbrella group** (`group:default/<team>`):

```yaml
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: payments-checkout-service
  annotations:
    backstage.io/kubernetes-id: payments-checkout-service
    backstage.io/kubernetes-namespace: team-payments-nonprod
spec:
  type: service
  lifecycle: production
  owner: group:default/team-payments
  system: payments-platform
```

---

## 4. Fallback Pattern: What If Corporate AD/LDAP Cannot Create Nested Umbrella Groups?

If your Active Directory / IAM team only issues flat groups (`team-payments-ro` and `team-payments-rw`) and cannot create a parent `team-payments` group in LDAP:

1. **Option A — Declare Lightweight Umbrella `Group` Entities in GitOps YAML:**
   Keep LDAP flat (`team-payments-ro`, `team-payments-rw` synced via `ldapOrg`) and commit a small `groups-umbrella.yaml` Catalog file in your platform GitOps repo declaring `kind: Group` (`name: team-payments`, `spec.children: [team-payments-ro, team-payments-rw]`). RHDH merges the Catalog relations seamlessly with your LDAP child groups, preserving the exact 2-role architecture above!
2. **Option B — Custom Metadata Annotation (`HAS_ANNOTATION`):**
   Stamp `platform.acme.io/team: payments` on entities and create per-team roles using `rule: HAS_ANNOTATION` (`annotation: platform.acme.io/team`, `value: payments`). Option A is strongly preferred over Option B because Option A keeps RHDH down to just 2 global roles.

---

## 5. Live Lab Verification Results (`alice`, `bob`, `carol`, `guest`)

This setup is deployed and verified live on the ROSA lab cluster (`namespace: rhdh` + `namespace: ldap`):
- **LDAP Manifests:** `rmallam-rhdh/RHDH-SM-DevSpaces` → `demo/ldap/bootstrap.ldif`
- **RHDH Helm & RBAC Manifests:** `rmallam-rhdh/rhdh-platform-gitops` → `charts/developer-hub/`

### Verified Ownership & Authorization Matrix

| User | Direct LDAP Group(s) | Transitive `$ownerRefs` Resolved by RHDH | Assigned RBAC Role | Visible Team Components (`payments` vs `retail`) | `update` / `delete` `payments-checkout-service` | `update` / `delete` `retail-inventory-service` | Delete Shared `Template` | Create / Run Scaffolder Templates |
| :--- | :--- | :--- | :--- | :--- | :---: | :---: | :---: | :---: |
| **`alice`** | `team-payments-rw` (+ `developers`) | `user:default/alice`, `group:default/team-payments-rw`, **`group:default/team-payments`**, `group:default/developers` | `role:default/team-editor` | **`payments-checkout-service`** (`retail-inventory-service` **HIDDEN**) | **ALLOW** | **DENY** | **DENY** | **ALLOW** |
| **`bob`** | `team-payments-ro` (+ `platform-team`) | `user:default/bob`, `group:default/team-payments-ro`, **`group:default/team-payments`**, `group:default/platform-team` | `role:default/team-viewer` | **`payments-checkout-service` ONLY** (`retail-inventory-service`, `orders-api`, `demo` **ALL HIDDEN**) | **DENY** | **DENY** | **DENY** | **DENY** |
| **`carol`** | `team-retail-rw`, `team-retail-ro` | `user:default/carol`, `group:default/team-retail-rw`, `group:default/team-retail-ro`, **`group:default/team-retail`** | `role:default/team-editor`, `role:default/team-viewer` | **`retail-inventory-service` ONLY** (`payments-checkout-service` **HIDDEN**) | **DENY** | **ALLOW** | **DENY** | **ALLOW** |
| **`guest`** | `superUsers` | `user:default/guest` (Super-Admin bypass) | `role:default/rbac_admin` + `superUsers` | **All Components** (`payments-checkout-service`, `retail-inventory-service`, `orders-api`, `demo`) | **ALLOW** | **ALLOW** | **ALLOW** | **ALLOW** |

### Onboarding Checklist for Adding a New Application Team (`payments`)
1. **AD / LDAP Team:** Create `rhdh-payments-ro`, `rhdh-payments-rw`, nest both inside `rhdh-payments-users`, and nest `rhdh-payments-users` inside `RHDH-users` (wait up to 5 minutes for `ldapOrg` sync).
2. **Platform GitOps (`values.yaml`):** Add the two group names under `permission.teamGroups` (hot-reloads automatically in ~60 seconds with **zero pod restarts**):
   ```yaml
   permission:
     teamGroups:
       readOnly:
         - rhdh-payments-ro
       readWrite:
         - rhdh-payments-rw
   ```
3. **App Team (`catalog-info.yaml` / Template):** Set `spec.owner: group:default/rhdh-payments-users`.

---

## 6. Customer Discovery Questions Checklist (Questions to Ask the IAM / AD / SSO Teams)

Before implementing this 3-level model in a customer environment, review these exact questions with the customer's **Active Directory / LDAP**, **SSO (Entra ID / OIDC)**, and **Platform Governance** teams:

### A. Questions for the Active Directory / LDAP Team

| # | Question to Ask | Why It Matters & How It Shapes Config |
| :- | :--- | :--- |
| **1** | **"Does your AD governance allow 3-level nested groups (`RHDH-users` → `rhdh-<team>-users` → `rhdh-<team>-ro` / `-rw`), and what is your required group naming prefix?"** | Confirms you can use the pure AD 3-level hierarchy. If IAM policy forbids nested AD groups, keep AD flat (`-ro` and `-rw` only) and declare the parent `rhdh-<team>-users` umbrella `Group` in GitOps YAML (Section 4, Option A). |
| **2** | **"What are the exact Base DNs (`usersDn` and `groupsDn`), and should RHDH bind to LDAPS (`636`) or AD Global Catalog LDAPS (`3269`)?"** | Multi-domain AD forests require Global Catalog (`3269`) if users and groups live in different child domains; single-domain AD uses standard LDAPS (`636`). |
| **3** | **"Does AD support recursive `LDAP_MATCHING_RULE_IN_CHAIN` (`1.2.840.113556.1.4.1941`) queries for our read-only bind account?"** | Allows RHDH to filter `ldapOrg` on `CN=RHDH-users` so RHDH only syncs onboarded RHDH users and groups rather than scanning 50,000+ corporate accounts. |
| **4** | **"Which LDAP attribute holds the user's unique corporate email / UPN (`mail` vs `userPrincipalName` vs `sAMAccountName`), and which group attribute holds members (`member`)?"** | Ensures `ldapOrg` `users.map.email` (or `name`) matches the SSO token claim at login. |

### B. Questions for the SSO / Microsoft Entra ID / OIDC Team

| # | Question to Ask | Why It Matters & How It Shapes Config |
| :- | :--- | :--- |
| **5** | **"On the RHDH SSO App Registration / Enterprise Application, is *'User Assignment Required'* enabled, and if so, does your IdP evaluate 2-level nested groups (`RHDH-users` → team → `-ro`/`-rw`)?"** | **Critical catch:** Microsoft Entra ID Enterprise App assignment often does **not** expand multi-level nested groups! If it does not: either **(a)** set *"Assignment required = No"* in Entra ID and let RHDH enforce login strictly via `RHDH-users` Catalog membership (`dangerouslyAllowSignInWithoutUserInCatalog: false`), or **(b)** assign the team groups directly to the Enterprise App. |
| **6** | **"Which claim in the OIDC / Entra ID token is guaranteed to match the LDAP `User` entity (`email`, `upn`, or `preferred_username`)?"** | Determines whether `signIn.resolvers` should use `emailMatchingUserEntityProfileEmail` (matches `spec.profile.email`) or `preferredUsernameMatchingUserEntityName` (matches `metadata.name`). |

### C. Questions for the Platform / Security Governance Team

| # | Question to Ask | Why It Matters & How It Shapes Config |
| :- | :--- | :--- |
| **7** | **"Which AD group owns the RHDH platform itself (Super-Admins who can see all teams and manage RBAC)?"** | Mapped to `permission.adminGroups` / `permission.superUsers` (e.g., `group:default/rhdh-platform-admins`). |
| **8** | **"Should a team's Read-Only (`-ro`) members be able to view runtime tabs (Kubernetes pods/logs, Argo CD sync status, Jenkins/Sonar) for their team's services, or Catalog metadata only?"** | By default, `role:default/team-viewer` allows read-only runtime tab visibility (`kubernetes.resources.read`, `argocd.view.read`) ONLY on entities the user can already see in the Catalog; those lines can be removed from `policiesCsv` if `-ro` should be metadata-only. |
| **9** | **"Are there any shared platform Systems, Domains, or APIs that *all* teams should be able to view (read-only), alongside Golden Path Templates?"** | If yes, add `Domain` or a specific tag/annotation rule (e.g., `HAS_LABEL: visibility=public`) to the `read` condition in `rbac-conditional-policies.yaml` — **never** set `spec.owner: group:default/rhdh-users`, as that would also grant `team-editor` write/delete access on those shared entities. |
