{{- define "squid.labels" -}}
app.kubernetes.io/name: squid
app.kubernetes.io/part-of: idp-platform
app.kubernetes.io/component: squid
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
