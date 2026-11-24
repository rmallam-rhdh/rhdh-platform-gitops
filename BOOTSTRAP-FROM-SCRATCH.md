# Recreating the Complete IDP Cluster From Scratch

This guide explains how to back up an existing lab cluster before deletion and recreate the entire **Red Hat Developer Hub (RHDH 1.10) + OpenShift Service Mesh 3 (Istio Ambient + Kiali) + OpenShift Dev Spaces + CloudNativePG** platform and all lab spikes from scratch on a new OpenShift / ROSA cluster.

---

## 1. Two-Repo GitOps Architecture

| Phase | GitHub Repository | What It Deploys |
|---|---|---|
| **Day-1 (Operators & Shared Tools)** | [`rmallam-rhdh/RHDH-SM-DevSpaces`](https://github.com/rmallam-rhdh/RHDH-SM-DevSpaces) | • OpenShift GitOps (`openshift-gitops-operator`) + controller `cluster-admin` RBAC<br>• CloudNativePG Operator (`cloudnative-pg`)<br>• Red Hat OpenShift Service Mesh 3 (`servicemeshoperator3`) & Kiali (`kiali-ossm`) Operators<br>• OpenShift Dev Spaces Operator (`devspaces`) + Webhook NetworkPolicy<br>• Red Hat Developer Hub Operator (`rhdh` `fast-1.10`)<br>• Cluster OVN `routingViaHost` job (`cluster-network`) & `ztunnel-healer`<br>• Namespace `network-isolation` NetworkPolicies + Seeder CronJob<br>• In-cluster tools: `jenkins`, `sonarqube`, `vault`, `ldap`, `saas-stubs` |
| **Day-2 (Platform CRs, Charts & Golden Paths)** | [`rmallam-rhdh/rhdh-platform-gitops`](https://github.com/rmallam-rhdh/rhdh-platform-gitops) (this repo) | • `cnpg` & `cnpg-dr`: 3-node CloudNativePG PostgreSQL clusters in `rhdh` and `rhdh-dr`<br>• `service-mesh`: `Istio` (Ambient profile), `IstioCNI`, `ZTunnel` (`istio-system`), `Kiali`, mesh-wide `STRICT` `PeerAuthentication`, and Prometheus `PodMonitor`/`ServiceMonitor` telemetry<br>• `devspaces`: hardened `CheCluster` (browser IDE disabled, desktop VS Code / Kiro landing page, per-user PVC, resource caps) + global `DevWorkspaceOperatorConfig` (30-day inactive cleanup)<br>• `devspaces-user-namespaces`: GitOps-provisioned per-user Dev Spaces namespaces, quotas, RBAC, and initial `DevWorkspace`<br>• `devspaces-multicluster-redirector`: Quarkus Multi-Cluster Redirector + OpenShift OAuth Proxy sidecar with structured datacenter AD group routing<br>• `squid`: authenticated egress proxy for RHDH SaaS calls<br>• `developer-hub`: RHDH `Backstage` CR, Command Centre overview/tab layout, dynamic plugins, RBAC, and permanent `rhdh-k8s-sa-token` Secret<br>• **Opt-in Lab Spikes (`argocd/apps-lab/`)**:<br>  - `cert-manager-operator` + `venafi-pki-lab` + `cnpg-venafi-tls` + `developer-hub-cnpg-tls` (Enterprise 2-tier PKI leaf-cert TLS for CNPG & RHDH via `NODE_EXTRA_CA_CERTS`)<br>  - `vault-namespace-lab` (Custom Vault Enterprise Namespace dynamic plugin with Kubernetes Auth)<br>  - `gateway-cert-lab` (Per-hostname `Certificate` + SNI Listener + `ReferenceGrant` on a shared Istio Gateway)<br>  - `command-centre-demo-apps` (`plugin-kitchen-sink-nonprod` & `plugin-kitchen-sink-prod` + Ambient Mesh traffic generator)<br>  - `kerberos-lab` + `developer-hub-kerberos` (Kerberos/NTLM proxy sidecar bridge spike) |

---

## 2. Step 0 — Back Up `rhdh-secrets` Before Deleting Your Current Cluster

Because live credentials (GitHub PAT/OAuth, Microsoft Entra ID, Jira Cloud, Dynatrace, ServiceNow) are never committed to Git, export `Secret/rhdh-secrets` from the current cluster before it is deleted:

```bash
oc get secret rhdh-secrets -n rhdh -o json \
  | jq 'del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp, .metadata.managedFields)' \
  > ~/rhdh-secrets-backup.json
```

> **Note:** You do **not** need to manually edit `KUBE_SA_TOKEN`, `KUBE_CA_DATA`, or `ARGOCD_ADMIN_PASSWORD` in `~/rhdh-secrets-backup.json` — `scripts/bootstrap-cluster.sh` automatically regenerates and patches those from the new cluster.

---

## 3. Step 1 — Update `clusterBaseDomain` for the New Cluster

Log into the new OpenShift / ROSA cluster as `cluster-admin` and inspect its ingress domain:

```bash
oc login https://api.<new-cluster>:443 -u cluster-admin -p <password> --insecure-skip-tls-verify=true
NEW_DOMAIN="$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')"
echo "New cluster base domain: ${NEW_DOMAIN}"
```

Update the cluster base domain (`apps.rosa.<old>...` -> `${NEW_DOMAIN}`) in the following files in this repository, commit, and push to `main`:

1. [`charts/developer-hub/values-deploy.yaml`](charts/developer-hub/values-deploy.yaml) (`app.clusterBaseDomain` and `app.devspacesBaseUrl`)
2. [`charts/gateway-cert-lab/values-deploy.yaml`](charts/gateway-cert-lab/values-deploy.yaml) (`clusterBaseDomain`)
3. [`charts/devspaces-user-namespaces/values.yaml`](charts/devspaces-user-namespaces/values.yaml) (`defaults.devSpacesBaseUrl`)
4. [`environments/nonprod/plugin-kitchen-sink/values.yaml`](environments/nonprod/plugin-kitchen-sink/values.yaml) & [`charts/demo-release/values.yaml`](charts/demo-release/values.yaml) (`trafficGenerator.clusterBaseDomain`)
5. [`golden-path/templates/template-nodejs-golden-path.yaml`](golden-path/templates/template-nodejs-golden-path.yaml) & [`golden-path/templates/template-quarkus-golden-path.yaml`](golden-path/templates/template-quarkus-golden-path.yaml) (`clusterBaseDomain.default` and `devSpacesBaseUrl.default`)

> **Microsoft Entra ID Redirect URI:** On the Entra App Registration (`rhdh-login`), add the new cluster's redirect URI:
> `https://backstage-developer-hub-rhdh.<NEW_DOMAIN>/api/auth/microsoft/handler/frame`

---

## 4. Step 2 — Install Day-1 Operators & Tools (`RHDH-SM-DevSpaces`)

```bash
git clone https://github.com/rmallam-rhdh/RHDH-SM-DevSpaces.git /tmp/RHDH-SM-DevSpaces

# 1. Install OpenShift GitOps Operator & cluster-admin ClusterRoleBinding
oc apply -k /tmp/RHDH-SM-DevSpaces/components/openshift-gitops/base

# Wait for OpenShift GitOps to initialize in namespace openshift-gitops
oc wait --for=condition=Available deploy/openshift-gitops-server -n openshift-gitops --timeout=300s

# 2. Apply Day-1 App-of-Apps (installs operators, network-isolation, jenkins, sonarqube, vault, ldap, saas-stubs)
oc apply -f /tmp/RHDH-SM-DevSpaces/bootstrap/root-app.yaml
```

Wait 2–3 minutes for OLM to finish installing the operator CSVs:

```bash
oc get csv -A | grep -E "rhdh|servicemesh|kiali|devspaces|cloudnative-pg"
```

---

## 5. Step 3 — Run the Day-2 Automated Bootstrap Script

From the root of `rhdh-platform-gitops`, run [`scripts/bootstrap-cluster.sh`](scripts/bootstrap-cluster.sh):

```bash
RHDH_SECRETS_FILE=~/rhdh-secrets-backup.json ./scripts/bootstrap-cluster.sh
```

*(If you want to also deploy the Kerberos/NTLM sidecar lab, prefix with `ENABLE_KERBEROS_LAB=true`)*.

### What `scripts/bootstrap-cluster.sh` Automates:
1. **OpenShift User Workload Monitoring**: Applies `ConfigMap/cluster-monitoring-config` (`enableUserWorkload: true`) in `openshift-monitoring` so Thanos/Prometheus scrapes Istio Ambient `ztunnel` and proxy `PodMonitor`/`ServiceMonitor` metrics for Kiali.
2. **Pre-requisite Namespaces & Labels**: Creates `rhdh`, `squid`, `jenkins`, `sonarqube`, `demo-dev`, `demo-prod` and labels `demo-dev` with `istio.io/dataplane-mode=ambient` and `istio-discovery=enabled`.
3. **Secrets & Dynamic Cluster Credentials**:
   - Applies `Secret/squid-htpasswd` in `squid` and `Secret/rhdh-secrets` in `rhdh`.
   - Creates `Secret/rhdh-k8s-sa-token` (`kubernetes.io/service-account-token`) in `rhdh` and injects the new cluster's `KUBE_SA_TOKEN` and `KUBE_CA_DATA` into `Secret/rhdh-secrets` (powering the RHDH Kubernetes and Kiali plugins).
   - Reads the live Argo CD `admin.password` from `Secret/openshift-gitops-cluster` in `openshift-gitops` and patches `ARGOCD_ADMIN_PASSWORD` into `Secret/rhdh-secrets`.
   - Syncs `SONARQUBE_API_KEY` from `rhdh/rhdh-secrets` into `Secret/sonarqube-token` (`SONAR_TOKEN`) in `namespace: jenkins` so Golden Path Jenkins pipelines can authenticate to SonarQube.
4. **Cluster RBAC & Argo CD App-of-Apps**:
   - Applies [`manifests/devspaces-multicluster-redirector/rbac.yaml`](manifests/devspaces-multicluster-redirector/rbac.yaml).
   - Applies [`argocd/app-of-apps.yaml`](argocd/app-of-apps.yaml) (`idp-platform`).
   - Applies the lab applications under [`argocd/apps-lab/`](argocd/apps-lab/).

---

## 6. Step 4 — Seed the Jenkins GitHub Organization Folder (`demo`)

Once Jenkins is running in `namespace: jenkins`, run the seeder script from `RHDH-SM-DevSpaces` so Jenkins automatically discovers and builds any repository created by the RHDH Golden Path templates:

```bash
JENKINS_URL="https://$(oc get route jenkins -n jenkins -o jsonpath='{.spec.host}')" \
JENKINS_USER="admin" \
JENKINS_PASSWORD="password" \
GITHUB_PAT="$(oc get secret rhdh-secrets -n rhdh -o jsonpath='{.data.GITHUB_TOKEN}' | base64 -d)" \
python3 /tmp/RHDH-SM-DevSpaces/demo/tools/jenkins-github-org.py
```

---

## 7. Verification Commands

```bash
# Check all Argo CD Applications
oc get applications.argoproj.io -n openshift-gitops

# Check RHDH & CloudNativePG
oc get cluster,backstage,pods,route -n rhdh

# Check Istio Ambient Mesh & Kiali
oc get istio,istiocni,ztunnel -A
oc get kiali,peerauthentication -n istio-system

# Check Dev Spaces & Multi-Cluster Redirector
oc get checluster -n openshift-devspaces
oc get pods,route -n devspaces-redirector
```
