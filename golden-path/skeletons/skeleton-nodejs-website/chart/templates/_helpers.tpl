{{- define "app.name" -}}
{{- default .Chart.Name .Values.name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "app.labels" -}}
app.kubernetes.io/name: {{ include "app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: acme-platform
backstage.io/kubernetes-id: {{ include "app.name" . }}
{{- end }}

{{- define "app.fqdn" -}}
{{- printf "%s.%s.svc.cluster.local" (include "app.name" .) .Release.Namespace }}
{{- end }}

{{- define "app.meshHost" -}}
{{- if .Values.mesh.host }}
{{- .Values.mesh.host }}
{{- else }}
{{- printf "%s-%s.%s" (include "app.name" .) .Release.Namespace .Values.clusterBaseDomain }}
{{- end }}
{{- end }}

{{- define "app.waypointName" -}}
{{- printf "%s-waypoint" (include "app.name" .) }}
{{- end }}

{{- define "app.gatewayRef" -}}
{{- printf "%s/%s" .Values.mesh.gateway.namespace .Values.mesh.gateway.name }}
{{- end }}
