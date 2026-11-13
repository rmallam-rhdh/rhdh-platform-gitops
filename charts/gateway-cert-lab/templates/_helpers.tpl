{{- define "gateway-cert-lab.labels" -}}
app.kubernetes.io/name: gateway-cert-lab
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: gateway-cert-lab
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{/* Hostname for a catalogue entry name: <name>-<prefix>.<domain> */}}
{{- define "gateway-cert-lab.host" -}}
{{- $root := index . 0 -}}{{- $name := index . 1 -}}
{{- printf "%s-%s.%s" $name $root.Values.namePrefix (required "clusterBaseDomain is required (values-deploy.yaml)" $root.Values.clusterBaseDomain) -}}
{{- end -}}
