{{- define "common.resourceQuota" -}}
{{- $root := .Root -}}
{{- $config := .Config | default $root.Values.resourceQuota -}}
{{- if and $config $config.enabled }}
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: {{ include "common.fullname" $root }}-quota
  namespace: {{ $root.Values.namespace | default $root.Release.Namespace }}
  labels:
{{- include "common.labels" $root | nindent 4 }}
spec:
  hard:
    {{- toYaml ($config.hard | required "resourceQuota.hard is required") | nindent 4 }}
{{- end }}
{{- end }}
