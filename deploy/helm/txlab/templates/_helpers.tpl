{{- define "txlab.name" -}}
{{ .Chart.Name }}
{{- end -}}

{{- define "txlab.fullname" -}}
{{ .Release.Name }}-{{ .Chart.Name }}
{{- end -}}
