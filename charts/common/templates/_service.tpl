{{- define "common.service" -}}
{{- $root := .Root }}
{{- $comp := .Component | default "app" }}
{{- $config := .Config | default $root.Values }}
{{- if not $config.service }}{{- /* service is optional — polling/batch workloads may not need one */ -}}
{{- else }}
apiVersion: v1
kind: Service
metadata:
  name: {{ $config.service.name | default (printf "%s-%s" (include "common.fullname" $root) $comp) }}
  namespace: {{ $root.Values.namespace | default $root.Release.Namespace }}
  labels:
{{- include "common.labels" $root | nindent 4 }}
  {{- with $config.service.annotations }}
  annotations:
{{ toYaml . | indent 4 }}
  {{- end }}
spec:
  type: {{ $config.service.type | default "ClusterIP" }}
  {{- with $config.service.loadBalancerIP }}
  loadBalancerIP: {{ . }}
  {{- end }}
  {{- with $config.service.externalTrafficPolicy }}
  externalTrafficPolicy: {{ . }}
  {{- end }}
  {{- with $config.service.loadBalancerClass }}
  loadBalancerClass: {{ . }}
  {{- end }}
  ports:
  {{- if $config.service.ports }}
  {{- range $config.service.ports }}
    - port: {{ .port }}
      targetPort: {{ .targetPort | default .port }}
      protocol: {{ .protocol | default "TCP" }}
      {{- if .name }}
      name: {{ .name | quote }}
      {{- end }}
  {{- end }}
  {{- else }}
    - port: {{ $config.service.port | required "service.port is required when service.ports is not configured" }}
      targetPort: {{ $config.service.targetPort | default $config.service.port }}
      protocol: TCP
      {{- if $config.service.portName }}
      name: {{ $config.service.portName }}
      {{- end }}
  {{- end }}
  selector:
  {{- with $config.service.selector }}
{{ toYaml . | indent 4 }}
  {{- else }}
    app.kubernetes.io/name: {{ include "common.fullname" $root }}
    app.kubernetes.io/component: {{ $comp }}
  {{- end }}
{{- end }}
{{- end }}
