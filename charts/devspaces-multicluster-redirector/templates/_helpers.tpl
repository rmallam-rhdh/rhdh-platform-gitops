{{- define "mcr.name" -}}
{{- default .Chart.Name .Values.nameOverride | toString | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "mcr.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | toString | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- .Release.Name | toString | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "mcr.namespace" -}}
{{- $ns := (.Values.namespace | default "") | toString | trim -}}
{{- default .Release.Namespace $ns | toString | trim -}}
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
{{- include "mcr.fullname" . -}}
{{- end -}}

{{- define "mcr.image" -}}
{{- if not (.Values.image).repository -}}
{{- fail "image.repository is required" -}}
{{- end -}}
{{- if (.Values.image).digest -}}
{{ (.Values.image).repository }}@{{ (.Values.image).digest }}
{{- else if (.Values.image).tag -}}
{{ (.Values.image).repository }}:{{ (.Values.image).tag }}
{{- else -}}
{{- fail "either image.tag or image.digest must be set" -}}
{{- end -}}
{{- end -}}

{{- define "mcr.sessionSecretKey" -}}
session_secret
{{- end -}}

{{- define "mcr.sessionSecretName" -}}
{{- printf "%s-session-secret" (include "mcr.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "mcr.oauthCallbackUrl" -}}
{{- if (.Values.route).oauthCallbackUrl -}}
{{- if not (regexMatch "^https?://" (.Values.route).oauthCallbackUrl) -}}
{{- fail "route.oauthCallbackUrl must start with http:// or https://" -}}
{{- end -}}
{{- (.Values.route).oauthCallbackUrl -}}
{{- else if (.Values.route).host -}}
https://{{ (.Values.route).host }}/oauth/callback
{{- else if and (.Values.venafi).enabled (.Values.venafi).hostname -}}
https://{{ (.Values.venafi).hostname }}/oauth/callback
{{- else -}}
{{- fail "route.oauthRedirectReference=false requires route.oauthCallbackUrl, route.host, or venafi.hostname" -}}
{{- end -}}
{{- end -}}

{{- define "mcr.environmentName" -}}
{{- (.Values.environmentName | default (.Values.venafi).environmentName | default "edev") | toString | trim -}}
{{- end -}}

{{- define "mcr.hostname" -}}
{{- $host := ((.Values.venafi).hostname | default (.Values.route).host | default "") | toString | trim -}}
{{- if not $host -}}
{{- fail "venafi.enabled=true requires venafi.hostname or route.host" -}}
{{- end -}}
{{- $host -}}
{{- end -}}

{{- define "mcr.gslbhostname" -}}
{{- $gslb := ((.Values.venafi).gslbHostname | default (.Values.venafi).gslbhostname | default .Values.gslbHostname | default .Values.gslbhostname | default "") | toString | trim -}}
{{- if not $gslb -}}
{{- fail "venafi.enabled=true with environmentName != \"edev\" requires venafi.gslbHostname" -}}
{{- end -}}
{{- $gslb -}}
{{- end -}}

{{- define "mcr.certificateName" -}}
{{- $override := ((.Values.venafi).certificateName | default "") | toString | trim -}}
{{- default (printf "%s-cert" (include "mcr.fullname" .)) $override | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "mcr.venafiCreateIssuer" -}}
{{- $issuerCfg := (.Values.venafi).issuer | default dict -}}
{{- if not (.Values.venafi).enabled -}}
false
{{- else if hasKey $issuerCfg "create" -}}
{{- ternary "true" "false" (eq ($issuerCfg.create | toString) "true") -}}
{{- else -}}
true
{{- end -}}
{{- end -}}

{{- define "mcr.venafiIssuerKind" -}}
{{- $issuerCfg := (.Values.venafi).issuer | default dict -}}
{{- ($issuerCfg.kind | default (.Values.venafi).issuerKind | default "Issuer") | toString | trim -}}
{{- end -}}

{{- define "mcr.venafiIssuerName" -}}
{{- $issuerCfg := (.Values.venafi).issuer | default dict -}}
{{- $override := ($issuerCfg.existingName | default (.Values.venafi).issuerName | default "") | toString | trim -}}
{{- default (printf "%s-issuer" (include "mcr.fullname" .)) $override | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "mcr.tlsCertificateSecretName" -}}
{{- $override := ((.Values.venafi).tlsCertificateSecretName | default "") | toString | trim -}}
{{- default (printf "%s-tls" (include "mcr.fullname" .)) $override | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "mcr.venafiCredentialsSecretName" -}}
{{- $tpp := (.Values.venafi).tpp | default dict -}}
{{- $defaultName := printf "%s-venafi-credentials" (include "mcr.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- $override := ($tpp.credentialsSecretName | default "") | toString | trim -}}
{{- default $defaultName $override -}}
{{- end -}}

{{- define "mcr.venafiZone" -}}
{{- $zone := ((.Values.venafi).zone | default "") | toString | trim -}}
{{- if not $zone -}}
{{- fail "venafi.enabled=true with venafi.issuer.create=true requires venafi.zone" -}}
{{- end -}}
{{- $zone -}}
{{- end -}}

{{- define "mcr.venafiTppUrl" -}}
{{- $tpp := (.Values.venafi).tpp | default dict -}}
{{- $url := ($tpp.url | default "") | toString | trim -}}
{{- if not $url -}}
{{- fail "venafi.enabled=true with venafi.issuer.create=true requires venafi.tpp.url" -}}
{{- end -}}
{{- $url -}}
{{- end -}}

{{- define "mcr.venafiTechnicalOwner" -}}
{{- $cf := (.Values.venafi).customFields | default dict -}}
{{- $owner := ($cf.technicalOwner | default (.Values.venafi).technicalOwner | default (.Values.venafi).venafiTechnicalOwner | default .Values.venafiTechnicalOwner | default "Platform Engineering") | toString | trim -}}
{{- if not $owner -}}
{{- fail "venafi.enabled=true requires venafi.customFields.technicalOwner" -}}
{{- end -}}
{{- $owner -}}
{{- end -}}

{{- define "mcr.venafiEnvironment" -}}
{{- $cf := (.Values.venafi).customFields | default dict -}}
{{- ($cf.environment | default (.Values.venafi).environment | default (.Values.venafi).venafiEnvironment | default .Values.venafiEnvironment | default (include "mcr.environmentName" .)) | toString | trim -}}
{{- end -}}

{{- define "mcr.venafiApplicationName" -}}
{{- $cf := (.Values.venafi).customFields | default dict -}}
{{- ($cf.applicationName | default (.Values.venafi).applicationName | default (.Values.venafi).venafiApplicationName | default .Values.venafiApplicationName | default (include "mcr.fullname" .)) | toString | trim -}}
{{- end -}}

{{- define "mcr.venafiAttachToRoute" -}}
{{- $venafi := .Values.venafi | default dict -}}
{{- if not $venafi.enabled -}}
false
{{- else if hasKey $venafi "attachToRoute" -}}
{{- ternary "true" "false" (eq ($venafi.attachToRoute | toString) "true") -}}
{{- else -}}
true
{{- end -}}
{{- end -}}
