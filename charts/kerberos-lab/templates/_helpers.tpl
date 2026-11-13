{{- define "kerberos-lab.name" -}}
kerberos-lab
{{- end -}}

{{- define "kerberos-lab.labels" -}}
app.kubernetes.io/name: {{ include "kerberos-lab.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: kerberos-lab
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}
