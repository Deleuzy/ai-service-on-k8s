{{- define "ai.name" -}}{{ .Release.Name }}-ai-service{{- end -}}
{{- define "ai.labels" -}}
app.kubernetes.io/name: ai-service
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Values.serviceVersion | quote }}
{{- end -}}
{{- define "ai.selector" -}}
app.kubernetes.io/name: ai-service
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
