{{- define "common.job" -}}
{{- $root := .Root }}
{{- $comp := .Component | default "job" }}
{{- $config := .Config | default dict }}
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ include "common.fullname" $root }}-{{ $comp }}
  namespace: {{ $root.Values.namespace | default $root.Release.Namespace }}
  labels:
    {{- include "common.labels" $root | nindent 4 }}
    app.kubernetes.io/component: {{ $comp }}
  {{- if $config.annotations }}
  annotations:
    {{- toYaml $config.annotations | nindent 4 }}
  {{- end }}
spec:
  backoffLimit: {{ $config.backoffLimit | default 3 }}
  {{- if $config.activeDeadlineSeconds }}
  activeDeadlineSeconds: {{ $config.activeDeadlineSeconds }}
  {{- end }}
  {{- if $config.ttlSecondsAfterFinished }}
  ttlSecondsAfterFinished: {{ $config.ttlSecondsAfterFinished }}
  {{- end }}
  template:
    metadata:
      labels:
        {{- include "common.labels" $root | nindent 8 }}
        app.kubernetes.io/component: {{ $comp }}
    spec:
      {{- if hasKey $config "automountServiceAccountToken" }}
      automountServiceAccountToken: {{ $config.automountServiceAccountToken }}
      {{- else if hasKey $root.Values "automountServiceAccountToken" }}
      automountServiceAccountToken: {{ $root.Values.automountServiceAccountToken }}
      {{- end }}
      restartPolicy: {{ $config.restartPolicy | default "OnFailure" }}
      {{- with (default $root.Values.podSecurityContext $config.podSecurityContext) }}
      securityContext:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with (default $root.Values.nodeSelector $config.nodeSelector) }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with (default $root.Values.imagePullSecrets $config.imagePullSecrets) }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- if $config.containers }}
      containers:
        {{- toYaml $config.containers | nindent 8 }}
      {{- else if $config.image }}
      containers:
        - name: {{ $comp }}
          image: "{{ $config.image.repository }}{{ if $config.image.tag }}:{{ $config.image.tag }}{{ end }}"
          {{- if $config.image.pullPolicy }}
          imagePullPolicy: {{ $config.image.pullPolicy }}
          {{- end }}
          {{- with $config.securityContext }}
          securityContext:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- if $config.command }}
          command:
            {{- toYaml $config.command | nindent 12 }}
          {{- end }}
          {{- if $config.args }}
          args:
            {{- toYaml $config.args | nindent 12 }}
          {{- end }}
          {{- if $config.env }}
          env:
          {{- range $key, $value := $config.env }}
            {{- if kindIs "map" $value }}
            - name: {{ $key }}
              {{- toYaml $value | nindent 14 }}
            {{- else if or (eq $value nil) (eq $value "") }}
            - name: {{ $key }}
              value: ""
            {{- else }}
            - name: {{ $key }}
              value: {{ $value | quote }}
            {{- end }}
          {{- end }}
          {{- end }}
          {{- with $config.resources }}
          resources:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- if $config.volumeMounts }}
          volumeMounts:
            {{- toYaml $config.volumeMounts | nindent 12 }}
          {{- end }}
      {{- end }}
      {{- if $config.volumes }}
      volumes:
        {{- toYaml $config.volumes | nindent 8 }}
      {{- end }}
{{- end }}
