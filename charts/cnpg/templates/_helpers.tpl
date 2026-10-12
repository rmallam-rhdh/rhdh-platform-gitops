{{- define "cnpg.namespace" -}}
{{- default "rhdh" .Values.namespace }}
{{- end }}

{{- define "cnpg.labels" -}}
app.kubernetes.io/name: cnpg
app.kubernetes.io/part-of: idp-platform
app.kubernetes.io/component: cnpg
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
