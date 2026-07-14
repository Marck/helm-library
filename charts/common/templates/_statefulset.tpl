{{- define "common.statefulset" -}}
{{- $root := .Root }}
{{- $comp := .Component | default "app" }}
{{- $config := .Config | default $root.Values }}
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: {{ include "common.fullname" $root }}-{{ $comp }}
  namespace: {{ $root.Values.namespace | default $root.Release.Namespace }}
  labels:
{{- include "common.labels" $root | nindent 4 }}
spec:
  revisionHistoryLimit: {{ $config.revisionHistoryLimit | default 3 }}
  replicas: {{ if (kindIs "invalid" $config.replicaCount) }}1{{ else }}{{ $config.replicaCount }}{{ end }}
  {{- with $config.updateStrategy }}
  updateStrategy:
{{ toYaml . | indent 4 }}
  {{- end }}
  serviceName: {{ $config.serviceName | default (printf "%s-%s" (include "common.fullname" $root) $comp) }}
  {{- if $config.podManagementPolicy }}
  podManagementPolicy: {{ $config.podManagementPolicy }}
  {{- end }}
  selector:
    matchLabels:
      app.kubernetes.io/name: {{ include "common.fullname" $root }}
      app.kubernetes.io/component: {{ $comp }}
  template:
    metadata:
      {{- $ctx := dict "Root" $root "Component" $comp "Config" $config -}}
      {{- $podAnnotationsYaml := include "common.annotations" $ctx -}}
      {{- if $podAnnotationsYaml }}
      annotations:
{{ $podAnnotationsYaml | indent 8 }}
      {{- end }}
      labels:
{{- include "common.labels" $root | nindent 8 }}
        app.kubernetes.io/component: {{ $comp }}
    spec:
      {{- if hasKey $config "automountServiceAccountToken" }}
      automountServiceAccountToken: {{ $config.automountServiceAccountToken }}
      {{- else if hasKey $root.Values "automountServiceAccountToken" }}
      automountServiceAccountToken: {{ $root.Values.automountServiceAccountToken }}
      {{- end }}
      {{- if $config.hostNetwork }}
      hostNetwork: {{ $config.hostNetwork }}
      {{- end }}
      {{- if or $config.dnsPolicy $config.hostNetwork }}
      dnsPolicy: {{ $config.dnsPolicy | default "ClusterFirstWithHostNet" }}
      {{- end }}
      {{- if or $config.podSecurityContext $root.Values.podSecurityContext }}
      securityContext:
{{ toYaml (default $root.Values.podSecurityContext $config.podSecurityContext) | indent 8 }}
      {{- end }}
      {{- if $config.initContainers }}
      initContainers:
      {{- toYaml $config.initContainers | nindent 6 }}
      {{- end }}
      containers:
        - name: {{ $comp }}
          image: "{{ $config.image.repository }}{{ if $config.image.tag }}:{{ $config.image.tag }}{{ end }}"
          {{- if $config.image.pullPolicy }}
          imagePullPolicy: {{ $config.image.pullPolicy }}
          {{- end }}
          {{- if or $config.securityContext $root.Values.securityContext }}
          securityContext:
{{ toYaml (default $root.Values.securityContext $config.securityContext) | indent 12 }}
          {{- end }}
          {{- if $config.command }}
          command:
{{ toYaml $config.command | indent 12 }}
          {{- end }}
          {{- if $config.args }}
          args:
{{ toYaml $config.args | indent 12 }}
          {{- end }}
          {{- if $config.env }}
          env:
          {{- range $key, $value := $config.env }}
            {{- if kindIs "map" $value }}
            - name: {{ $key }}
{{ toYaml $value | indent 14 }}
            {{- else if or (eq $value nil) (eq $value "") }}
            - name: {{ $key }}
              value: ""
            {{- else }}
            - name: {{ $key }}
              value: {{ $value | quote }}
            {{- end }}
          {{- end }}
          {{- end }}
          ports:
          {{- if $config.ports }}
          {{- range $config.ports }}
            - containerPort: {{ .containerPort }}
              {{- if .protocol }}
              protocol: {{ .protocol }}
              {{- end }}
              {{- if .name }}
              name: {{ .name }}
              {{- end }}
          {{- end }}
          {{- else }}
            - containerPort: {{ $config.service.port | required "service.port is required when ports is not configured" }}
              {{- if $config.service.portName }}
              name: {{ $config.service.portName }}
              {{- end }}
          {{- end }}
          {{- if $config.probes }}
          {{- if $config.probes.liveness }}
          {{- if $config.probes.liveness.enabled }}
          livenessProbe:
            {{- if $config.probes.liveness.httpGet }}
            httpGet:
{{ toYaml $config.probes.liveness.httpGet | indent 14 }}
            {{- else if $config.probes.liveness.tcpSocket }}
            tcpSocket:
{{ toYaml $config.probes.liveness.tcpSocket | indent 14 }}
            {{- else if $config.probes.liveness.exec }}
            exec:
{{ toYaml $config.probes.liveness.exec | indent 14 }}
            {{- else if $config.probes.liveness.grpc }}
            grpc:
{{ toYaml $config.probes.liveness.grpc | indent 14 }}
            {{- end }}
            initialDelaySeconds: {{ $config.probes.liveness.initialDelaySeconds | default 0 }}
            periodSeconds: {{ $config.probes.liveness.periodSeconds | default 10 }}
            timeoutSeconds: {{ $config.probes.liveness.timeoutSeconds | default 1 }}
            failureThreshold: {{ $config.probes.liveness.failureThreshold | default 3 }}
          {{- end }}
          {{- end }}
          {{- if $config.probes.readiness }}
          {{- if $config.probes.readiness.enabled }}
          readinessProbe:
            {{- if $config.probes.readiness.httpGet }}
            httpGet:
{{ toYaml $config.probes.readiness.httpGet | indent 14 }}
            {{- else if $config.probes.readiness.tcpSocket }}
            tcpSocket:
{{ toYaml $config.probes.readiness.tcpSocket | indent 14 }}
            {{- else if $config.probes.readiness.exec }}
            exec:
{{ toYaml $config.probes.readiness.exec | indent 14 }}
            {{- else if $config.probes.readiness.grpc }}
            grpc:
{{ toYaml $config.probes.readiness.grpc | indent 14 }}
            {{- end }}
            initialDelaySeconds: {{ $config.probes.readiness.initialDelaySeconds | default 0 }}
            periodSeconds: {{ $config.probes.readiness.periodSeconds | default 10 }}
            timeoutSeconds: {{ $config.probes.readiness.timeoutSeconds | default 1 }}
            failureThreshold: {{ $config.probes.readiness.failureThreshold | default 3 }}
          {{- end }}
          {{- end }}
          {{- end }}
          {{- if $config.resources }}
          resources:
{{ toYaml $config.resources | indent 12 }}
          {{- end }}
          {{- if $config.volumeMounts }}
          volumeMounts:
{{ tpl (toYaml $config.volumeMounts) $root | indent 12 }}
          {{- end }}
      {{- if $config.volumes }}
      volumes:
{{ tpl (toYaml $config.volumes) $root | indent 8 }}
      {{- end }}
{{- if or $config.nodeSelector $root.Values.nodeSelector }}
      nodeSelector:
{{ toYaml (default $root.Values.nodeSelector $config.nodeSelector) | indent 8 }}
{{- end }}
{{- if or $config.affinity $root.Values.affinity }}
      affinity:
{{ toYaml (default $root.Values.affinity $config.affinity) | indent 6 }}
{{- end }}
{{- if or $config.tolerations $root.Values.tolerations }}
      tolerations:
{{ toYaml (default $root.Values.tolerations $config.tolerations) | indent 6 }}
{{- end }}
  {{- if $config.volumeClaimTemplates }}
  volumeClaimTemplates:
{{ toYaml $config.volumeClaimTemplates | indent 4 }}
  {{- end }}
{{- end }}
