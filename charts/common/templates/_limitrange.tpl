{{- define "common.limitRange" -}}
{{- $root := .Root -}}
{{- $config := .Config | default $root.Values.limitRange -}}
{{- if and $config $config.enabled }}
---
apiVersion: v1
kind: LimitRange
metadata:
  name: {{ include "common.fullname" $root }}-limits
  namespace: {{ $root.Values.namespace | default $root.Release.Namespace }}
  labels:
{{- include "common.labels" $root | nindent 4 }}
spec:
  limits:
    {{- toYaml ($config.limits | required "limitRange.limits is required") | nindent 4 }}
{{- end }}
{{- end }}
