{{- /*
  common.daemonset — a DaemonSet counterpart to common.deployment. Same value
  shape (image/env/probes/volumes/securityContext/hostNetwork/tolerations/…) so a
  component can move between the two helpers with no value changes. Used for
  per-node agents (a metrics or log collector, say) that must run one pod on every
  node. There is no replicaCount/strategy here; DaemonSets use updateStrategy.
*/ -}}
{{- define "common.daemonset" -}}
{{- $root := .Root }}
{{- $comp := .Component | default "app" }}
{{- $config := .Config | default $root.Values }}
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: {{ include "common.fullname" $root }}-{{ $comp }}
  namespace: {{ $root.Values.namespace | default $root.Release.Namespace }}
  {{- with $config.deploymentAnnotations }}
  annotations:
{{ toYaml . | indent 4 }}
  {{- end }}
  labels:
{{- include "common.labels" $root | nindent 4 }}
spec:
  revisionHistoryLimit: {{ $config.revisionHistoryLimit | default 3 }}
  updateStrategy:
    type: {{ $config.updateStrategy | default "RollingUpdate" }}
    {{- if eq ($config.updateStrategy | default "RollingUpdate") "RollingUpdate" }}
    {{- if $config.rollingUpdate }}
    rollingUpdate:
{{ toYaml $config.rollingUpdate | indent 6 }}
    {{- end }}
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
        {{- with $config.podLabels }}
{{ toYaml . | indent 8 }}
        {{- end }}
    spec:
      {{- $sa := (default $root.Values.serviceAccount $config.serviceAccount) | default dict }}
      {{- if or $sa.create $sa.name }}
      serviceAccountName: {{ $sa.name | default (include "common.serviceAccountName" $root) }}
      {{- end }}
      {{- if hasKey $config "automountServiceAccountToken" }}
      automountServiceAccountToken: {{ $config.automountServiceAccountToken }}
      {{- else if hasKey $root.Values "automountServiceAccountToken" }}
      automountServiceAccountToken: {{ $root.Values.automountServiceAccountToken }}
      {{- end }}
      {{- if $config.hostNetwork }}
      hostNetwork: {{ $config.hostNetwork }}
      {{- end }}
      {{- if $config.hostPID }}
      hostPID: {{ $config.hostPID }}
      {{- end }}
      {{- if or $config.dnsPolicy $config.hostNetwork }}
      dnsPolicy: {{ $config.dnsPolicy | default "ClusterFirstWithHostNet" }}
      {{- end }}
      {{- with (default $root.Values.hostAliases $config.hostAliases) }}
      hostAliases:
{{ toYaml . | indent 6 }}
      {{- end }}
      {{- if or $config.imagePullSecrets $root.Values.imagePullSecrets }}
      imagePullSecrets:
{{ toYaml (default $root.Values.imagePullSecrets $config.imagePullSecrets) | indent 6 }}
      {{- end }}
      {{- if or $config.podSecurityContext $root.Values.podSecurityContext }}
      securityContext:
{{ toYaml (default $root.Values.podSecurityContext $config.podSecurityContext) | indent 8 }}
      {{- end }}
      {{- $inits := include "common.initContainers" (dict "Root" $root "Config" $config) }}
      {{- if trim $inits }}
      initContainers:
      {{- $inits | trim | nindent 6 }}
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
          {{- if $config.envFrom }}
          envFrom:
{{ tpl (toYaml $config.envFrom) $root | indent 12 }}
          {{- end }}
          {{- if $config.ports }}
          ports:
          {{- range $config.ports }}
            - containerPort: {{ .containerPort }}
              {{- if .protocol }}
              protocol: {{ .protocol }}
              {{- end }}
              {{- if .hostPort }}
              hostPort: {{ .hostPort }}
              {{- end }}
              {{- if .hostIP }}
              hostIP: {{ .hostIP | quote }}
              {{- end }}
              {{- if .name }}
              name: {{ .name }}
              {{- end }}
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
      {{- if $config.additionalContainers }}
{{ toYaml $config.additionalContainers | indent 8 }}
      {{- end }}
      {{- if $config.volumes }}
      volumes:
{{ tpl (toYaml $config.volumes) $root | indent 8 }}
      {{- end }}
{{- /* A DaemonSet usually wants NO nodeSelector (run on every node). Honour an
       explicitly-set component nodeSelector — even an empty map, which means
       "clear the inherited default" — otherwise fall back to the chart default. */ -}}
{{- if hasKey $config "nodeSelector" }}
{{- if $config.nodeSelector }}
      nodeSelector:
{{ toYaml $config.nodeSelector | indent 8 }}
{{- end }}
{{- else if $root.Values.nodeSelector }}
      nodeSelector:
{{ toYaml $root.Values.nodeSelector | indent 8 }}
{{- end }}
{{- if or $config.affinity $root.Values.affinity }}
      affinity:
{{ toYaml (default $root.Values.affinity $config.affinity) | indent 6 }}
{{- end }}
{{- if or $config.tolerations $root.Values.tolerations }}
      tolerations:
{{ toYaml (default $root.Values.tolerations $config.tolerations) | indent 6 }}
{{- end }}
{{- end }}
