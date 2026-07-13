{{- define "common.namespace" -}}
{{- $annotations := dict "argocd.argoproj.io/sync-wave" "-1" -}}
{{- if .Values.namespaceAnnotations -}}
  {{- $annotations = mergeOverwrite $annotations .Values.namespaceAnnotations -}}
{{- end -}}
{{- /* Node-selector namespace annotation (PodNodeSelector admission). Emitted
   from .Values.nodeSelector, but a consumer can suppress it with the scalar
   nodeSelectorEnabled: false — a map default can't be cleared via Helm merge,
   so an explicit boolean is the only clean per-app override (e.g. a chart whose
   pods must run cluster-wide). Defaults to true → existing behaviour unchanged. */ -}}
{{- $nodeSelectorEnabled := true -}}
{{- if hasKey .Values "nodeSelectorEnabled" -}}
  {{- $nodeSelectorEnabled = .Values.nodeSelectorEnabled -}}
{{- end -}}
{{- if and .Values.nodeSelector $nodeSelectorEnabled -}}
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
