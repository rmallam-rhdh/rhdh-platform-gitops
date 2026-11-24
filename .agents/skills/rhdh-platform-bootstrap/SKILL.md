---
name: rhdh-platform-bootstrap
description: >-
  End-to-end runbook and automation guide to bootstrap, recreate from scratch,
  or audit the Red Hat Developer Hub (RHDH 1.10), OpenShift Service Mesh 3
  (Istio Ambient + Kiali), OpenShift Dev Spaces (Desktop-Only + Multi-Cluster
  Redirector), CloudNativePG (CNPG + Venafi TLS), Squid Proxy, Kerberos/NTLM
  Bridge, Vault Enterprise Namespace plugin, and Golden Path CI/CD (Jenkins +
  SonarQube + Argo CD) platform on a fresh OpenShift / ROSA cluster. Use
  whenever spinning up a new cluster, migrating before cluster deletion, or
  verifying GitOps sync across `rmallam-rhdh/RHDH-SM-DevSpaces` (Day-1) and
  `rmallam-rhdh/rhdh-platform-gitops` (Day-2).
---

# RHDH + Service Mesh 3 Ambient + Dev Spaces Platform Bootstrap Skill

This skill provides the deterministic procedure to recreate the complete Internal Developer Platform (IDP) and all lab spikes from scratch on any OpenShift 4.16+ / ROSA cluster, or to back up credentials before a cluster is deleted.

See the full repository runbook at [BOOTSTRAP-FROM-SCRATCH.md](../../BOOTSTRAP-FROM-SCRATCH.md) and the automated bootstrap script at [scripts/bootstrap-cluster.sh](../../scripts/bootstrap-cluster.sh).

## Quick Execution Sequence

1. **Before old cluster deletion** — back up `Secret/rhdh-secrets`:
   ```bash
   oc get secret rhdh-secrets -n rhdh -o json | jq 'del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp, .metadata.managedFields)' > ~/rhdh-secrets-backup.json
   ```
2. **On the new cluster** — update `clusterBaseDomain` in:
   - `charts/developer-hub/values-deploy.yaml`
   - `charts/gateway-cert-lab/values-deploy.yaml`
   - `charts/devspaces-user-namespaces/values.yaml`
   - `environments/nonprod/plugin-kitchen-sink/values.yaml` & `charts/demo-release/values.yaml`
   - `golden-path/templates/template-nodejs-golden-path.yaml` & `golden-path/templates/template-quarkus-golden-path.yaml`
3. **Install Day-1 Operators & Tools (`RHDH-SM-DevSpaces`)**:
   ```bash
   git clone https://github.com/rmallam-rhdh/RHDH-SM-DevSpaces.git /tmp/RHDH-SM-DevSpaces
   oc apply -k /tmp/RHDH-SM-DevSpaces/components/openshift-gitops/base
   oc wait --for=condition=Available deploy/openshift-gitops-server -n openshift-gitops --timeout=300s
   oc apply -f /tmp/RHDH-SM-DevSpaces/bootstrap/root-app.yaml
   ```
4. **Run Day-2 Bootstrap Script (`rhdh-platform-gitops`)**:
   ```bash
   RHDH_SECRETS_FILE=~/rhdh-secrets-backup.json ./scripts/bootstrap-cluster.sh
   ```
5. **Seed Jenkins GitHub Organization Folder (`demo`)**:
   ```bash
   JENKINS_URL="https://$(oc get route jenkins -n jenkins -o jsonpath='{.spec.host}')" \
   GITHUB_PAT="$(oc get secret rhdh-secrets -n rhdh -o jsonpath='{.data.GITHUB_TOKEN}' | base64 -d)" \
   python3 /tmp/RHDH-SM-DevSpaces/demo/tools/jenkins-github-org.py
   ```
