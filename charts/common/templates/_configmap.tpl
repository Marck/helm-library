{{- define "common.configmap" -}}
{{- $root := .Root }}
{{- if kindIs "slice" $root.Values.configmap }}
{{- /* Support for multiple configmaps */ -}}
{{- range $index, $cm := $root.Values.configmap }}
{{- if $cm.enabled }}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ $cm.name | default (printf "%s-cm-%d" (include "common.fullname" $root) $index) }}
  namespace: {{ $root.Values.namespace | default $root.Release.Namespace }}
  labels:
{{- include "common.labels" $root | nindent 4 }}
{{- if $cm.data }}
data:
{{- toYaml $cm.data | nindent 2 }}
{{- end }}
{{- end }}
{{- end }}
{{- else if $root.Values.configmap.enabled }}
{{- /* Support for single configmap */ -}}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ $root.Values.configmap.name | default (printf "%s-cm" (include "common.fullname" $root)) }}
  namespace: {{ $root.Values.namespace | default $root.Release.Namespace }}
  labels:
{{- include "common.labels" $root | nindent 4 }}
{{- if $root.Values.configmap.data }}
data:
{{- toYaml $root.Values.configmap.data | nindent 2 }}
{{- end }}
{{- end }}
{{- end }}
