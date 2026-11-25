# RHDH 1.10 Branding & "Command Centre" Bento UI Portability Guide

This guide explains how to deploy our corporate Blue/Slate branding theme and the **6-Tab Command Centre Bento UI** into any customer Red Hat Developer Hub (RHDH 1.10) environment using standalone Kubernetes `ConfigMap` manifests — **without rebuilding containers or touching dynamic plugin packages**.

Ready-to-apply cluster manifests live in [`examples/branding-and-bento-ui/`](../examples/branding-and-bento-ui/):
1. [`01-configmap-branding.example.yaml`](../examples/branding-and-bento-ui/01-configmap-branding.example.yaml) — Corporate Royal Blue & Clean Slate theme (Light + Dark mode)
2. [`02-configmap-command-centre-bento.example.yaml`](../examples/branding-and-bento-ui/02-configmap-command-centre-bento.example.yaml) — Default Bento Overview Grid + 6-Tab Command Centre layout
3. [`03-backstage-cr-patch.example.yaml`](../examples/branding-and-bento-ui/03-backstage-cr-patch.example.yaml) — `Backstage` CR `appConfig.configMaps` wiring snippet

---

## 1. Key Questions Answered (Customer FAQ)

### Q1: Do we have to touch or rebuild any plugins for Branding or the Bento View?
**No.** Neither customization touches plugin packages or container images:
- **Branding (`app-config-rhdh-branding`):** Uses RHDH's native `app.branding.theme` configuration schema.
- **Bento View & Consolidated Tabs (`app-config-command-centre`):** Uses RHDH's native `dynamicPlugins.frontend` layout engine (`mountPoints` and `entityTabs`), which is read directly from `app-config` ConfigMaps! Your `dynamic-plugins` ConfigMap keeps its standard package list untouched.

### Q2: Once mounted on the `Backstage` CR, does the UI turn Blue immediately and is Bento the default for *all* Catalog components?
**Yes to both:**
1. As soon as the two ConfigMaps are listed under `spec.application.appConfig.configMaps` on the `Backstage` CR (and the RHDH Operator rolls the pod), the **entire RHDH portal switches to the Blue/Slate palette immediately** (sidebar, headers, cards, tables, buttons, and dark mode).
2. The **Bento Overview Grid + 6-Tab Command Centre layout becomes the global default for every Catalog entity** (`Component`) automatically — teams do **not** change anything in their repos except standard tool annotations (`backstage.io/kubernetes-id`, `argocd/app-selector`, `jenkins.io/job-full-name`, `sonarqube.org/project-key`, etc.). Each Bento card uses an `if:` guard so an entity only displays cards for the tools it actually uses.

### Q3: What if the customer uses Bitbucket instead of GitHub?
**Zero changes are required to either ConfigMap:**
- Neither `app-config-rhdh-branding` nor `app-config-command-centre` references GitHub! Every Bento card (`ArgocdDeploymentSummary`, `EntityLatestJenkinsRunCard`, `EntitySonarQubeCard`, `EntityPagerDutySmallCard`) and all 6 tabs (`Overview`, `CI/CD`, `Quality & Security`, `Runtime`, `Operations`, `Docs`) are 100% SCM-agnostic and work identically with **Bitbucket Cloud** or **Bitbucket Data Center / Server**.
- In the customer's main `app-config-rhdh`, enable the `integrations.bitbucketServer` (or `bitbucketCloud`) block and enable the Bitbucket catalog/scaffolder modules in `dynamic-plugins`.
- On Bitbucket-backed `catalog-info.yaml` files, standard `backstage.io/source-location: url:https://bitbucket.example.com/projects/PROJ/repos/my-service/browse/` automatically renders the "View Source" link in the `About` card. *(If the customer also enables `roadiehq-backstage-plugin-bitbucket-pullrequest`, simply uncomment the Bitbucket PR `mountPoints` block included in `02-configmap-command-centre-bento.example.yaml` to mount Bitbucket PRs inside the `CI/CD` tab.)*

---

## 2. What These Two ConfigMaps Solve Under the Hood

### A. Corporate Blue/Slate Branding (`01-configmap-branding.example.yaml`)
- **Full Light & Dark Mode RHDH v1.10 Tokens:** Overrides not only MUI `primary`/`secondary`, but also RHDH 1.10's custom `palette.rhdh.general` (`pageInset: 1rem`, `sidebarBackgroundColor`, `cardBorderColor`, `tableRowHover`, `appBarBackgroundColor`) and `palette.rhdh.cards` (`headerBackgroundImage: none`).
- **Header Tab Contrast Fix (`options.tabs: mui`):** Fixes RHDH 1.10's default `BackstageHeaderTabs` CSS bug (`color: unset`) that otherwise renders unselected tabs low-contrast against dark navy/blue gradient headers.

### B. Command Centre Bento Layout (`02-configmap-command-centre-bento.example.yaml`)
1. **Breakpoint-Aligned Bento Grid (`gridColumnEnd`):**
   - Backstage's built-in `About` and `Links` cards use MUI v4 breakpoints (`lg = 1280px`, occupying 6 of 12 columns on 1280px laptops and 4 of 12 columns on `>=1536px` monitors), while RHDH dynamic plugin cards use MUI v5 `sx` breakpoints (`lg = 1200px`).
   - Pairing `xl: "span 4"` (`xl: "span 8"` for Argo CD) with `lg: "span 6"` and `md: "span 6"` guarantees cards pack cleanly beside `About + Links` with **zero empty white-space gaps** on both laptop and widescreen displays.
   - CSS constraints (`maxHeight: 230px–240px`, internal scrollbars) prevent a single verbose plugin card from stretching an entire row.
2. **Collapsing 14+ Plugin Tabs into 6 Domain Tabs:**
   Uses `entityTabs` `priority` ordering (`100` down to `50`) and hides individual plugin tabs with `priority: -1`:

| Tab Order | Tab Title | Mount Point | Consolidated Plugins Inside Tab |
| :---: | :--- | :--- | :--- |
| **1** | **Overview** (`priority: 100`) | `entity.page.overview` | `About`, `Links`, + Compact Bento KPI Cards (Argo CD, Jenkins, SonarQube, PagerDuty) |
| **2** | **CI/CD** (`priority: 90`) | `entity.page.cicd` | Multi-Cluster Argo CD Lifecycle + Jenkins Builds + Tekton Pipelines *(+ optional Bitbucket PRs)* |
| **3** | **Quality & Security** (`priority: 80`) | `entity.page.quality-security` | SonarQube Full Report + JFrog Artifactory *(+ optional Snyk / Vault)* |
| **4** | **Runtime** (`priority: 70`) | `entity.page.runtime` | OpenShift Topology (`65vh`) + Kubernetes Workloads/Pods/Logs + Kiali Service Mesh |
| **5** | **Operations** (`priority: 60`) | `entity.page.operations` | Dynatrace Problems/Metrics + PagerDuty + Jira Issues + ServiceNow CMDB/Changes |
| **6** | **Docs** (`priority: 50`) | `entity.page.docs` | TechDocs |

*(Individual `/cd`, `/ci`, `/image-registry`, `/topology`, `/kubernetes`, `/kiali`, `/dynatrace`, `/monitoring`, `/jira`, `/issues`, `/servicenow`, `/dependencies`, and `/api` tabs are hidden via `priority: -1` so the top tab bar stays clean.)*

---

## 3. Step-by-Step Deployment in a Customer Cluster

### Option A: Apply Standalone Cluster Manifests (Raw YAML / Kustomize / Argo CD)

1. **Edit `title` and `baseUrl` (and optional logos/colors)** in [`01-configmap-branding.example.yaml`](../examples/branding-and-bento-ui/01-configmap-branding.example.yaml):
   ```yaml
   app:
     title: "Customer Developer Portal"
     baseUrl: "https://backstage-developer-hub-rhdh.apps.<customer-cluster-domain>"
   ```
   *(Optional: To add the customer's SVG wordmark and sidebar icon, base64-encode the SVGs via `base64 -i logo.svg | tr -d '\n'` and uncomment `fullLogo` and `iconLogo`.)*

2. **Apply or commit both ConfigMaps** into the RHDH namespace (e.g. `rhdh`):
   ```bash
   oc apply -n rhdh -f examples/branding-and-bento-ui/01-configmap-branding.example.yaml
   oc apply -n rhdh -f examples/branding-and-bento-ui/02-configmap-command-centre-bento.example.yaml
   ```

3. **Mount both ConfigMaps on the `Backstage` CR** (see [`03-backstage-cr-patch.example.yaml`](../examples/branding-and-bento-ui/03-backstage-cr-patch.example.yaml)):
   ```yaml
   spec:
     application:
       appConfig:
         mountPath: /opt/app-root/src
         configMaps:
           - name: app-config-rhdh
           - name: app-config-rhdh-branding
           - name: app-config-command-centre
   ```
   The RHDH Operator automatically detects the new `appConfig.configMaps` entries, updates `rhdh.redhat.com/ext-config-hash`, and performs a rolling update of `backstage-developer-hub`.

---

### Option B: Using This Repository's Helm Chart (`charts/developer-hub`)

Both features are already built in and **enabled by default** in [`charts/developer-hub/values.yaml`](../charts/developer-hub/values.yaml):

```yaml
instance:
  extraFiles:
    branding: true

commandCentreLayout:
  enabled: true

branding:
  enabled: true
  pageInset: "1rem"
  light:
    primaryColor: "#2563EB"
    secondaryColor: "#0284C7"
    headerStart: "#0F172A"
    headerEnd: "#1E3A8A"
    # ... (override any hex token per customer brand guidelines)
```

---

## 4. Expected Catalog Entity Annotations (Bitbucket Example)

To light up the Bento cards and domain tabs on a Bitbucket-hosted microservice, include the matching annotations for the tools that service uses in its `catalog-info.yaml`:

```yaml
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: payments-checkout-service
  description: "Payments Checkout Service"
  annotations:
    # Bitbucket Server / Data Center source link (or bitbucket.org for Cloud)
    backstage.io/source-location: url:https://bitbucket.example.com/projects/PAY/repos/payments-checkout-service/browse/
    backstage.io/techdocs-ref: dir:.
    # Runtime Tab (Topology + Kubernetes + Kiali)
    backstage.io/kubernetes-id: payments-checkout-service
    backstage.io/kubernetes-namespace: team-payments-nonprod
    # Overview Bento + CI/CD Tab (Argo CD + Jenkins)
    argocd/app-selector: app.kubernetes.io/instance=payments-checkout-service
    jenkins.io/job-full-name: payments/payments-checkout-service
    # Overview Bento + Quality & Security Tab
    sonarqube.org/project-key: payments-checkout-service
    jfrog-artifactory/image-names: payments-checkout-service
    # Overview Bento + Operations Tab
    pagerduty.com/service-id: P123456
    jira/project-key: PAY
    servicenow.com/entity-id: payments-checkout-service
spec:
  type: service
  lifecycle: production
  owner: group:default/rhdh-payments-users
  system: payments-platform
```
