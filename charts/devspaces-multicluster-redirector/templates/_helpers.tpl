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

{{- define "mcr.image" -}}
{{- if not .Values.image.repository -}}
{{- fail "image.repository is required" -}}
{{- end -}}
{{- if .Values.image.digest -}}
{{ .Values.image.repository }}@{{ .Values.image.digest }}
{{- else if .Values.image.tag -}}
{{ .Values.image.repository }}:{{ .Values.image.tag }}
{{- else -}}
{{- fail "either image.tag or image.digest must be set" -}}
{{- end -}}
{{- end -}}

{{- define "mcr.sessionSecretMode" -}}
{{- $mode := .Values.sessionSecret.mode | default "vaultStaticSecret" -}}
{{- if not .Values.sessionSecret.create -}}
{{- $mode = "external" -}}
{{- end -}}
{{- if not (has $mode (list "vaultStaticSecret" "eso" "external" "secret")) -}}
{{- fail (printf "sessionSecret.mode %q must be one of: vaultStaticSecret, eso, external, secret" $mode) -}}
{{- end -}}
{{- $mode -}}
{{- end -}}

{{- define "mcr.sessionSecretKey" -}}
{{- $key := .Values.sessionSecret.secretKey | default "session_secret" | trim -}}
{{- if not $key -}}
{{- fail "sessionSecret.secretKey must not be empty" -}}
{{- end -}}
{{- $key -}}
{{- end -}}

{{- define "mcr.sessionSecretName" -}}
{{- $mode := include "mcr.sessionSecretMode" . -}}
{{- if eq $mode "external" -}}
{{- if not .Values.sessionSecret.existingSecret -}}
{{- fail "sessionSecret mode=external (or create=false) requires sessionSecret.existingSecret" -}}
{{- end -}}
{{- .Values.sessionSecret.existingSecret -}}
{{- else if eq $mode "vaultStaticSecret" -}}
{{- .Values.sessionSecret.vaultStaticSecret.destinationSecretName | default .Values.sessionSecret.existingSecret | default (printf "%s-session-secret" (include "mcr.fullname" .)) -}}
{{- else if eq $mode "eso" -}}
{{- .Values.sessionSecret.eso.targetSecretName | default .Values.sessionSecret.existingSecret | default (printf "%s-session-secret" (include "mcr.fullname" .)) -}}
{{- else -}}
{{ include "mcr.fullname" . }}-session-secret
{{- end -}}
{{- end -}}

{{- define "mcr.oauthCallbackUrl" -}}
{{- if .Values.route.oauthCallbackUrl -}}
{{- if not (regexMatch "^https?://" .Values.route.oauthCallbackUrl) -}}
{{- fail "route.oauthCallbackUrl must start with http:// or https://" -}}
{{- end -}}
{{- .Values.route.oauthCallbackUrl -}}
{{- else if .Values.route.host -}}
https://{{ .Values.route.host }}/oauth/callback
{{- else if and .Values.venafi.enabled .Values.venafi.hostname -}}
https://{{ .Values.venafi.hostname }}/oauth/callback
{{- else -}}
{{- fail "route.oauthRedirectReference=false requires route.oauthCallbackUrl, route.host, or venafi.hostname" -}}
{{- end -}}
{{- end -}}

{{- define "mcr.namespace" -}}
{{- default .Release.Namespace .Values.namespace -}}
{{- end -}}

{{- define "mcr.environmentName" -}}
{{- .Values.environmentName | default .Values.venafi.environmentName | default "edev" | trim -}}
{{- end -}}

{{- define "mcr.hostname" -}}
{{- $host := .Values.venafi.hostname | default .Values.route.host | trim -}}
{{- if not $host -}}
{{- fail "venafi.enabled=true requires venafi.hostname or route.host" -}}
{{- end -}}
{{- $host -}}
{{- end -}}

{{- define "mcr.gslbhostname" -}}
{{- $gslb := .Values.venafi.gslbHostname | trim -}}
{{- if not $gslb -}}
{{- fail "venafi.enabled=true with environmentName != \"edev\" requires venafi.gslbHostname" -}}
{{- end -}}
{{- $gslb -}}
{{- end -}}

{{- define "mcr.certificateName" -}}
{{- default (include "mcr.namespace" .) (.Values.venafi.certificateName | trim) -}}
{{- end -}}

{{- define "mcr.venafiIssuerName" -}}
{{- $issuer := .Values.venafi.issuerName | trim -}}
{{- if not $issuer -}}
{{- fail "venafi.enabled=true requires venafi.issuerName" -}}
{{- end -}}
{{- $issuer -}}
{{- end -}}

{{- define "mcr.tlsCertificateSecretName" -}}
{{- $sec := .Values.venafi.tlsCertificateSecretName | trim -}}
{{- if not $sec -}}
{{- fail "venafi.enabled=true requires venafi.tlsCertificateSecretName" -}}
{{- end -}}
{{- $sec -}}
{{- end -}}

{{- define "mcr.venafiTechnicalOwner" -}}
{{- $owner := .Values.venafi.customFields.technicalOwner | trim -}}
{{- if not $owner -}}
{{- fail "venafi.enabled=true requires venafi.customFields.technicalOwner" -}}
{{- end -}}
{{- $owner -}}
{{- end -}}

{{- define "mcr.venafiEnvironment" -}}
{{- .Values.venafi.customFields.environment | default (include "mcr.environmentName" .) | trim -}}
{{- end -}}

{{- define "mcr.venafiApplicationName" -}}
{{- .Values.venafi.customFields.applicationName | default (include "mcr.fullname" .) | trim -}}
{{- end -}}
