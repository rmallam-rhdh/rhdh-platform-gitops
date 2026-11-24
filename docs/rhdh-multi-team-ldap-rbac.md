# Multi-Team Catalog Isolation & LDAP RBAC in Red Hat Developer Hub (RHDH 1.10)

This guide documents the production-grade multi-team onboarding and Role-Based Access Control (RBAC) architecture implemented and verified in Red Hat Developer Hub (RHDH 1.10 / Backstage 1.49.4), answering the two core enterprise questions:

1. **Authentication & Onboarding:** How multiple application teams log in to RHDH and bind to their synced LDAP `User` and `Group` entities without manual user creation.
2. **Per-Team Read-Only (`-ro`) & Read-Write (`-rw`) Catalog Isolation:** How to restrict each team to see **only their own catalog entities** (plus shared platform `Template`, `User`, and `Group` entities) while keeping separate Read-Only and Read-Write LDAP groups per team — **without creating `2 × N` custom RBAC roles as you scale to dozens of teams**.

---

## 1. Architecture Overview (Option 1: Nested LDAP Umbrella Groups + 2 Reusable Roles)

In Backstage and RHDH, every Catalog entity (`Component`, `System`, `API`, `Resource`) has a **single** `spec.owner` field (for example, `spec.owner: group:default/team-payments`).

If a team has two separate LDAP groups — `team-payments-ro` (viewers) and `team-payments-rw` (editors) — making both groups match `spec.owner: group:default/team-payments` cleanly at scale uses **Nested LDAP Umbrella Groups** paired with **Transitive Group Ownership** (`includeTransitiveGroupOwnership: true`):

```
OpenLDAP / Active Directory Hierarchy (ou=groups,dc=acme,dc=demo)
├── cn=team-payments              <── Catalog Entity spec.owner: group:default/team-payments
│   ├── cn=team-payments-rw       <── Bound to role:default/team-editor  (e.g., uid=alice)
│   └── cn=team-payments-ro       <── Bound to role:default/team-viewer  (e.g., uid=bob)
│
└── cn=team-retail                <── Catalog Entity spec.owner: group:default/team-retail
    ├── cn=team-retail-rw         <── Bound to role:default/team-editor  (e.g., uid=carol)
    └── cn=team-retail-ro         <── Bound to role:default/team-viewer
```

### Why This Is the Enterprise Best Practice
- **Only 2 RBAC roles ever exist in RHDH:** `role:default/team-viewer` and `role:default/team-editor`.
- **Onboarding Team #50 requires 2 lines in `rbac-policies.csv`** (`g, group:default/team-foo-ro, role:default/team-viewer` and `g, group:default/team-foo-rw, role:default/team-editor`) and **zero changes** to `rbac-conditional-policies.yaml`.
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

# Parent Umbrella Group (owns Catalog Entities: spec.owner: group:default/team-payments)
dn: cn=team-payments,ou=groups,dc=acme,dc=demo
objectClass: groupOfNames
cn: team-payments
description: Payments Team Umbrella Ownership Group
member: cn=team-payments-rw,ou=groups,dc=acme,dc=demo
member: cn=team-payments-ro,ou=groups,dc=acme,dc=demo
```

> **Active Directory Note:** If using Microsoft Active Directory where nested groups rely on `LDAP_MATCHING_RULE_IN_CHAIN` or `memberOf`, RHDH's `ldapOrg` group mapper resolves nested group DNs directly as long as `groups.map.members: member` points to the `member` attribute containing child group DNs.

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
    policies-csv-file: /opt/app-root/src/rbac-policies.csv
    conditionalPoliciesFile: /opt/app-root/src/rbac-conditional-policies.yaml
    policyFileReload: true
```

---

### Step 3: Configure `rbac-policies.csv` (Non-Conditional Actions & Group-to-Role Bindings)

Mount `rbac-policies.csv` via a `ConfigMap` under `spec.application.extraFiles.configMaps` on the `Backstage` CR.

> **Important Gotcha:** Do **not** add unconditional `p, role:default/team-viewer, catalog-entity, read, allow` or `p, role:default/team-editor, catalog-entity, read, allow` lines in `rbac-policies.csv`. All `catalog-entity` permissions (`read`, `update`, `delete`) must come **exclusively** from `rbac-conditional-policies.yaml` so global allow rules never shadow ownership conditions.

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

# Onboarding teams: bind each child LDAP group to team-viewer (-ro) or team-editor (-rw)
g, group:default/team-payments-ro, role:default/team-viewer
g, group:default/team-payments-rw, role:default/team-editor
g, group:default/team-retail-ro, role:default/team-viewer
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

### Onboarding Checklist for Adding a New Application Team (`team-<name>`)
1. Create `cn=team-<name>-ro`, `cn=team-<name>-rw`, and parent `cn=team-<name>` in LDAP (wait up to 5 minutes for `ldapOrg` sync, or restart/refresh catalog).
2. Add two lines to `permission.policiesCsv` in `values.yaml`:
   ```csv
   g, group:default/team-<name>-ro, role:default/team-viewer
   g, group:default/team-<name>-rw, role:default/team-editor
   ```
3. Set `spec.owner: group:default/team-<name>` in the team's `catalog-info.yaml` (or Golden Path template `OwnerPicker`). Because `policyFileReload: true` is enabled, RHDH reloads `rbac-policies.csv` automatically when the ConfigMap updates.
