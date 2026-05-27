{{- define "common.sealedsecret" -}}
{{- $root := .Root }}
{{- $config := .Config | default $root.Values }}
{{- if $config.sealedSecrets }}
{{- range $config.sealedSecrets }}
{{- if .enabled }}
---
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: {{ .name | default (include "common.fullname" $root) }}
  namespace: {{ .namespace | default $root.Release.Namespace }}
  annotations:
    sealedsecrets.bitnami.com/{{ .scope | default "namespace-wide" }}: "true"
spec:
  encryptedData:
  {{- toYaml .templateData | nindent 4 }}
  template:
    type: {{ .type | default "Opaque" }}
    metadata:
      annotations:
        sealedsecrets.bitnami.com/{{ .scope | default "namespace-wide" }}: "true"
      labels:
        {{- include "common.labels" $root | nindent 8 }}
{{- end }}
{{- end }}
{{- else if $root.Values.sealedSecret }}
{{- if $root.Values.sealedSecret.enabled }}
---
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: {{ $root.Values.sealedSecret.name | default (include "common.fullname" $root) }}
  namespace: {{ $root.Values.namespace | default $root.Release.Namespace }}
  annotations:
    sealedsecrets.bitnami.com/{{ $root.Values.sealedSecret.scope | default "namespace-wide" }}: "true"
spec:
  encryptedData:
  {{- toYaml $root.Values.sealedSecret.templateData | nindent 4 }}
  template:
    type: Opaque
    metadata:
      annotations:
        sealedsecrets.bitnami.com/{{ $root.Values.sealedSecret.scope | default "namespace-wide" }}: "true"
      labels:
        {{- include "common.labels" $root | nindent 8 }}
{{- end }}
{{- end }}
{{- end }}
