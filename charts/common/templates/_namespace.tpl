{{- define "common.namespace" -}}
{{- $annotations := dict "argocd.argoproj.io/sync-wave" "-1" -}}
{{- if .Values.namespaceAnnotations -}}
  {{- $annotations = mergeOverwrite $annotations .Values.namespaceAnnotations -}}
{{- end -}}
{{- if .Values.nodeSelector -}}
  {{- $parts := list -}}
  {{- range $k, $v := .Values.nodeSelector -}}
    {{- $parts = append $parts (printf "%s=%s" $k $v) -}}
  {{- end -}}
  {{- $_ := set $annotations "scheduler.alpha.kubernetes.io/node-selector" (join "," $parts) -}}
{{- end -}}
apiVersion: v1
kind: Namespace
metadata:
  name: {{ .Values.namespace | default .Release.Namespace }}
  labels:
{{- include "common.labels" . | nindent 4 }}
{{- if .Values.namespaceLabels }}
{{- toYaml .Values.namespaceLabels | nindent 4 }}
{{- end }}
{{- if and .Values.podSecurity .Values.podSecurity.enabled }}
    pod-security.kubernetes.io/enforce: {{ .Values.podSecurity.enforce | default "baseline" }}
    pod-security.kubernetes.io/audit: {{ .Values.podSecurity.audit | default "restricted" }}
    pod-security.kubernetes.io/warn: {{ .Values.podSecurity.warn | default "restricted" }}
{{- end }}
{{- if not (empty $annotations) }}
  annotations:
{{- toYaml $annotations | nindent 4 }}
{{- end }}
{{- end }}
