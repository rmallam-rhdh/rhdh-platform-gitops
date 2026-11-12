{{- define "mcr.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "mcr.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- include "mcr.name" . -}}
{{- end -}}
{{- end -}}

{{- define "mcr.labels" -}}
app.kubernetes.io/name: {{ include "mcr.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: idp-platform
app.kubernetes.io/component: multicluster-redirector
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "mcr.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mcr.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "mcr.serviceAccountName" -}}
{{ include "mcr.fullname" . }}
{{- end -}}

{{- define "mcr.sessionSecretName" -}}
{{- if not .Values.sessionSecret.create -}}
{{- if not .Values.sessionSecret.existingSecret -}}
{{- fail "sessionSecret.create=false requires sessionSecret.existingSecret" -}}
{{- end -}}
{{- .Values.sessionSecret.existingSecret -}}
{{- else -}}
{{ include "mcr.fullname" . }}-session-secret
{{- end -}}
{{- end -}}

{{- define "mcr.oauthCallbackUrl" -}}
{{- if .Values.route.oauthCallbackUrl -}}
{{- .Values.route.oauthCallbackUrl -}}
{{- else if .Values.route.host -}}
https://{{ .Values.route.host }}/oauth/callback
{{- else -}}
{{- end -}}
{{- end -}}
