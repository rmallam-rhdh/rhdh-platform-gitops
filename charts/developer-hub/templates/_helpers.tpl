{{- define "rhdh.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "rhdh.fullname" -}}
{{- default "developer-hub" .Values.instance.name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "rhdh.namespace" -}}
{{- default "rhdh" .Values.namespace }}
{{- end }}

{{- define "rhdh.labels" -}}
app.kubernetes.io/name: {{ include "rhdh.name" . }}
app.kubernetes.io/instance: {{ include "rhdh.fullname" . }}
app.kubernetes.io/part-of: acme-platform
app.kubernetes.io/component: developer-hub
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end }}

{{- define "rhdh.baseUrl" -}}
{{- if .Values.app.baseUrl -}}
{{- .Values.app.baseUrl -}}
{{- else -}}
https://backstage-{{ include "rhdh.fullname" . }}-{{ include "rhdh.namespace" . }}.{{ .Values.app.clusterBaseDomain }}
{{- end -}}
{{- end }}

{{- define "rhdh.plugin" -}}
  - package: {{ .package | quote }}
    disabled: {{ if .enabled }}false{{ else }}true{{ end }}
{{- if .pluginConfig }}
    pluginConfig:
{{ .pluginConfig | toYaml | nindent 6 }}
{{- end }}
{{- end }}
