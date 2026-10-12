{{- define "mesh.labels" -}}
app.kubernetes.io/name: service-mesh
app.kubernetes.io/part-of: idp-platform
app.kubernetes.io/component: service-mesh
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
