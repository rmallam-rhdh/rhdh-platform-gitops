#!/usr/bin/env bash
# Unit: helm lint + template. System: rendered YAML must include the plugin set
# with live OCI pins and a valid Backstage CR.
set -euo pipefail
CHART="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$CHART/../.." && pwd)"
need() { command -v "$1" >/dev/null || { echo "missing $1" >&2; exit 1; }; }
need helm
need ruby

fail=0
helm lint "$CHART"

render() {
  local out="$1"
  shift
  helm template rhdh "$CHART" --namespace rhdh "$@" >"$out"
}

PROD="$(mktemp)"
DEMO="$(mktemp)"
trap 'rm -f "$PROD" "$DEMO"' EXIT

render "$PROD" -f "$CHART/values.yaml"
render "$DEMO" -f "$CHART/values.yaml" -f "$CHART/values-demo.yaml"

check_file() {
  local file="$1" label="$2"
  echo "== $label =="
  for pat in \
    "kind: Backstage" \
    "dynamicPluginsConfigMapName: dynamic-plugins-rhdh" \
    "name: rhdh-secrets" \
    "storage: 8Gi" \
    "backstage-community-plugin-jenkins" \
    "backstage-plugin-catalog-backend-module-ldap-dynamic" \
    "backstage-plugin-scaffolder-backend-module-github-dynamic" \
    "backstage-plugin-kubernetes" \
    "backstage-community-plugin-tekton" \
    "backstage-community-plugin-argocd" \
    "backstage-community-plugin-sonarqube" \
    "rhdh-plugin-snyk" \
    "roadiehq-backstage-plugin-jira" \
    "backstage-community-plugin-jfrog-artifactory" \
    "backstage-community-plugin-vault" \
    "backstage-community-plugin-servicenow" \
    "backstage-community-plugin-dynatrace" \
    "backstage-community-plugin-kiali" \
    "apic-backstage" \
    "backstage-plugin-techdocs" \
    "bs_1.49.4__2.5.10" \
    "rbac-policies.csv"
  do
    if grep -q "$pat" "$file"; then
      echo "OK  $pat"
    else
      echo "FAIL missing $pat"
      fail=1
    fi
  done
}

check_file "$PROD" "production"
check_file "$DEMO" "demo"

# Demo overlay: guest login + ESO (secrets live in Vault).
grep -q "name: user:default/guest" "$DEMO" || { echo "FAIL demo missing guest admin object"; fail=1; }
grep -q "kind: ExternalSecret" "$DEMO" || { echo "FAIL demo missing ExternalSecret"; fail=1; }
grep -q "kind: ExternalSecret" "$PROD" || { echo "FAIL production missing ExternalSecret"; fail=1; }
grep -q "remoteRef:" "$DEMO" || { echo "FAIL demo ExternalSecret missing remoteRef"; fail=1; }
grep -q "dangerouslyAllowOutsideDevelopment" "$DEMO" || { echo "FAIL demo missing guest provider"; fail=1; }
grep -q "kubernetes.clusters.read" "$DEMO" || { echo "FAIL demo missing kubernetes.clusters.read"; fail=1; }
grep -q "kubernetes.resources.read" "$DEMO" || { echo "FAIL demo missing kubernetes.resources.read"; fail=1; }
for perm in scaffolder.template.parameter.read scaffolder.template.step.read scaffolder.action.execute catalog.location.create catalog.location.read; do
  grep -q "$perm" "$DEMO" || { echo "FAIL demo missing $perm"; fail=1; }
  grep -q "$perm" "$PROD" || { echo "FAIL prod missing $perm"; fail=1; }
done
grep -q "automountServiceAccountToken: true" "$DEMO" || { echo "FAIL demo missing SA token automount"; fail=1; }
grep -q "metrics.k8s.io" "$DEMO" || { echo "FAIL demo missing metrics.k8s.io ClusterRole"; fail=1; }
grep -q "enableLocalDb: false" "$DEMO" || { echo "FAIL demo must disable bundled Postgres"; fail=1; }
grep -q "postgresql.cnpg.io/v1" "$DEMO" || { echo "FAIL demo missing CNPG Cluster"; fail=1; }
grep -q "name: rhdh-pg" "$DEMO" || { echo "FAIL demo missing rhdh-pg cluster"; fail=1; }
grep -q "POSTGRES_HOST" "$DEMO" || { echo "FAIL demo missing POSTGRES_HOST env"; fail=1; }
grep -q "enableLocalDb: true" "$PROD" || { echo "FAIL prod default should keep local DB unless CNPG is on"; fail=1; }
grep -q "postgresql.cnpg.io/v1" "$PROD" && { echo "FAIL prod must not emit CNPG Cluster by default"; fail=1; }
grep -q "name: rhdh-demo-catalog" "$DEMO" || { echo "FAIL demo missing kitchen-sink ConfigMap"; fail=1; }
grep -q "plugin-kitchen-sink" "$DEMO" || { echo "FAIL demo missing kitchen-sink entity"; fail=1; }
grep -q "jira/project-key: SCRUM" "$DEMO" || { echo "FAIL demo kitchen-sink must use Jira project SCRUM"; fail=1; }
grep -q "entity.page.jira" "$DEMO" || { echo "FAIL demo missing Jira entity tab mount"; fail=1; }
grep -q "title: Jira" "$DEMO" || { echo "FAIL demo missing Jira tab title"; fail=1; }
grep -q "entity.page.dynatrace" "$DEMO" || { echo "FAIL demo missing Dynatrace entity tab mount"; fail=1; }
grep -q "SERVICE-39720C1E0047A5C0" "$DEMO" || { echo "FAIL demo kitchen-sink must use a real Dynatrace SERVICE id"; fail=1; }
grep -q "entity.page.kiali" "$DEMO" || { echo "FAIL demo missing Kiali entity tab mount"; fail=1; }
grep -q "kiali.io/namespace: demo-dev" "$DEMO" || { echo "FAIL demo kitchen-sink missing kiali.io/namespace"; fail=1; }
grep -q "dynatrace-access-token" "$DEMO" || { echo "FAIL demo ExternalSecret missing dynatrace-access-token"; fail=1; }
grep -q "vault.io/secrets-path" "$DEMO" || { echo "FAIL demo missing vault annotation"; fail=1; }
grep -q "name: rhdh-demo-catalog" "$PROD" && { echo "FAIL prod must not ship kitchen-sink ConfigMap"; fail=1; }
grep -q "/dynatrace:" "$PROD" && { echo "FAIL prod must not emit /dynatrace proxy without apiTarget"; fail=1; }

# Parse the generated dynamic-plugins.yaml out of the ConfigMap.
ruby - "$DEMO" <<'RUBY'
require "yaml"
doc = File.read(ARGV[0])
cm = doc.split(/^---\n/).find { |b| b.include?("name: dynamic-plugins-rhdh") && b.include?("dynamic-plugins.yaml:") }
abort "no dynamic-plugins ConfigMap" unless cm
# Helm indents the literal block 4 spaces under data:
inner = cm[/dynamic-plugins\.yaml: \|\n(.*?)(\nkind: |\z)/m, 1]
abort "empty plugin yaml" if inner.nil? || inner.strip.empty?
unindented = inner.lines.map { |l| l.sub(/^    /, "") }.join
d = YAML.safe_load(unindented)
pkgs = (d["plugins"] || []).map { |p| p["package"] }
raise "no plugins" if pkgs.empty?
disabled = (d["plugins"] || []).select { |p| p["disabled"] == true }
allowed = disabled.select { |p| p["package"].to_s.match?(/msgraph|keycloak/) }
unless disabled == allowed
  raise "unexpected disabled plugins: #{disabled.map { |p| p["package"] }}"
end
vault = pkgs.find { |p| p.to_s.include?("plugin-vault") }
raise "vault package missing" unless vault
raise "vault should be enabled" if d["plugins"].find { |p| p["package"] == vault }["disabled"]
bb = pkgs.find { |p| p.to_s.include?("bitbucket-cloud") }
raise "bitbucket package missing" unless bb
raise "bitbucket should be enabled" if d["plugins"].find { |p| p["package"] == bb }["disabled"]
oci = pkgs.select { |p| p.to_s.start_with?("oci://") }
snyk = pkgs.find { |p| p.to_s.include?("rhdh-plugin-snyk") }
raise "snyk package missing" unless snyk
raise "snyk should be enabled" if d["plugins"].find { |p| p["package"] == snyk }["disabled"]
puts "OK  #{pkgs.size} plugins (#{oci.size} OCI, #{disabled.size} disabled)"
RUBY

ruby - "$DEMO" <<'RUBY'
require "yaml"
doc = File.read(ARGV[0])
cm = doc.split(/^---\n/).find { |b| b.include?("name: app-config-rhdh\n") && b.include?("app-config.yaml:") }
abort "no app-config ConfigMap" unless cm
inner = cm[/app-config\.yaml: \|\n(.*?)(\nkind: |\z)/m, 1]
abort "empty app-config" if inner.nil? || inner.strip.empty?
unindented = inner.lines.map { |l| l.sub(/^    /, "") }.join
d = YAML.safe_load(unindented)
%w[app auth catalog jenkins argocd kubernetes snyk permission].each do |k|
  raise "missing app-config key #{k}" unless d.key?(k)
end
raise "guest missing" unless d.dig("auth", "providers", "guest")
raise "snyk should be mocked in demo" unless d.dig("snyk", "mocked") == true
jenkins_url = d.dig("jenkins", "instances", 0, "baseUrl")
raise "demo jenkins url #{jenkins_url}" unless jenkins_url == "http://jenkins.jenkins.svc"
sonar_url = d.dig("sonarqube", "baseUrl")
raise "demo sonar url #{sonar_url}" unless sonar_url == "http://sonarqube.sonarqube.svc:9000"
jira_url = d.dig("jira", "baseUrl")
raise "demo jira url #{jira_url}" unless jira_url == "https://mallamrakeshkumar.atlassian.net"
raise "demo jira must use cloud search (POST /search/jql)" unless d.dig("jira", "product") == "cloud"
proxy_jira = d.dig("proxy", "endpoints", "/jira/api") || {}
unless Array(proxy_jira["allowedMethods"]).include?("POST")
  raise "demo jira proxy must allow POST for /search/jql"
end
jira_auth = proxy_jira.dig("headers", "Authorization").to_s
raise "demo jira proxy must send Basic ${JIRA_TOKEN}, not Bearer" unless jira_auth == "${JIRA_TOKEN}"
proxy_dt = d.dig("proxy", "endpoints", "/dynatrace") || {}
raise "demo missing /dynatrace proxy" if proxy_dt.empty?
raise "demo dynatrace proxy target #{proxy_dt["target"]}" unless proxy_dt["target"] == "https://wkf10640.live.dynatrace.com/api/v2"
dt_auth = proxy_dt.dig("headers", "Authorization").to_s
raise "demo dynatrace proxy must send Api-Token" unless dt_auth.start_with?("Api-Token ")
locs = d.dig("catalog", "locations") || []
file_loc = locs.find { |l| l["target"].to_s.include?("catalog-demo/catalog-info.yaml") }
raise "demo missing kitchen-sink file location" unless file_loc
ks_tpl = locs.find { |l| l["target"].to_s.include?("template-plugin-kitchen-sink.yaml") }
raise "demo missing kitchen-sink template location" unless ks_tpl
gp_tpl = locs.find { |l| l["target"].to_s.include?("template-nodejs-golden-path.yaml") }
raise "demo missing nodejs golden-path template location" unless gp_tpl
qx_tpl = locs.find { |l| l["target"].to_s.include?("template-quarkus-golden-path.yaml") }
raise "demo missing quarkus golden-path template location" unless qx_tpl
web_tpl = locs.find { |l| l["target"].to_s.include?("template-nodejs-website.yaml") }
raise "demo missing nodejs website template location" unless web_tpl
db = d.dig("backend", "database") || {}
raise "demo missing backend.database.client pg" unless db["client"] == "pg"
raise "demo missing pluginDivisionMode schema" unless db["pluginDivisionMode"] == "schema"
puts "OK  app-config keys #{d.keys.size} (guest+mocked snyk+in-cluster tools)"
RUBY

# No accidental live tokens in rendered YAML.
if grep -E 'ghp_|gho_|sk-|sha256~' "$PROD" "$DEMO"; then
  echo "FAIL rendered manifests look like they contain secrets"
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "Helm chart tests failed"
  exit 1
fi
echo "Helm chart tests passed"
