{{- define "common.cronjob" -}}
{{- $root := .Root }}
{{- $comp := .Component | default "cronjob" }}
{{- $config := .Config | default dict }}
apiVersion: batch/v1
kind: CronJob
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
  schedule: {{ $config.schedule | required "config.schedule is required for common.cronjob" | quote }}
  {{- if hasKey $config "suspend" }}
  suspend: {{ $config.suspend }}
  {{- end }}
  concurrencyPolicy: {{ $config.concurrencyPolicy | default "Forbid" }}
  successfulJobsHistoryLimit: {{ $config.successfulJobsHistoryLimit | default 3 }}
  failedJobsHistoryLimit: {{ $config.failedJobsHistoryLimit | default 1 }}
  jobTemplate:
    spec:
      backoffLimit: {{ $config.backoffLimit | default 3 }}
      {{- if $config.activeDeadlineSeconds }}
      activeDeadlineSeconds: {{ $config.activeDeadlineSeconds }}
      {{- end }}
      {{- /* hasKey (not `default`) so ttlSecondsAfterFinished: 0 — delete a
             finished Job immediately — is honoured; the field auto-GCs finished
             Jobs (Complete AND Failed) instead of leaving them to accumulate up
             to failedJobsHistoryLimit. Omitted by default (charts unchanged). */}}
      {{- if hasKey $config "ttlSecondsAfterFinished" }}
      ttlSecondsAfterFinished: {{ $config.ttlSecondsAfterFinished }}
      {{- end }}
      template:
        metadata:
          labels:
            {{- include "common.labels" $root | nindent 12 }}
            app.kubernetes.io/component: {{ $comp }}
        spec:
          {{- /* Same SA resolution as common.deployment — set when created or named */}}
          {{- $sa := (default $root.Values.serviceAccount $config.serviceAccount) | default dict }}
          {{- if or $sa.create $sa.name }}
          serviceAccountName: {{ $sa.name | default (include "common.serviceAccountName" $root) }}
          {{- end }}
          {{- if hasKey $config "automountServiceAccountToken" }}
          automountServiceAccountToken: {{ $config.automountServiceAccountToken }}
          {{- else if hasKey $root.Values "automountServiceAccountToken" }}
          automountServiceAccountToken: {{ $root.Values.automountServiceAccountToken }}
          {{- end }}
          restartPolicy: {{ $config.restartPolicy | default "OnFailure" }}
          {{- with (default $root.Values.podSecurityContext $config.podSecurityContext) }}
          securityContext:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with (default $root.Values.nodeSelector $config.nodeSelector) }}
          nodeSelector:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with (default $root.Values.imagePullSecrets $config.imagePullSecrets) }}
          imagePullSecrets:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- /* Init containers run before the job's own container: the usual use is
                 preparing a mounted volume the Job cannot prepare itself, e.g. an
                 NFS share whose directory must be chowned to the unprivileged uid
                 the Job runs as. */}}
          {{- with $config.initContainers }}
          initContainers:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- if $config.containers }}
          containers:
            {{- toYaml $config.containers | nindent 12 }}
          {{- else if $config.image }}
          containers:
            - name: {{ $comp }}
              image: "{{ $config.image.repository }}{{ if $config.image.tag }}:{{ $config.image.tag }}{{ end }}"
              {{- if $config.image.pullPolicy }}
              imagePullPolicy: {{ $config.image.pullPolicy }}
              {{- end }}
              {{- with $config.securityContext }}
              securityContext:
                {{- toYaml . | nindent 16 }}
              {{- end }}
              {{- if $config.command }}
              command:
                {{- toYaml $config.command | nindent 16 }}
              {{- end }}
              {{- if $config.args }}
              args:
                {{- toYaml $config.args | nindent 16 }}
              {{- end }}
              {{- if $config.env }}
              env:
              {{- range $key, $value := $config.env }}
                {{- if kindIs "map" $value }}
                - name: {{ $key }}
                  {{- toYaml $value | nindent 18 }}
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
                {{- toYaml . | nindent 16 }}
              {{- end }}
              {{- if $config.volumeMounts }}
              volumeMounts:
                {{- toYaml $config.volumeMounts | nindent 16 }}
              {{- end }}
          {{- end }}
          {{- if $config.volumes }}
          volumes:
            {{- toYaml $config.volumes | nindent 12 }}
          {{- end }}
{{- end }}
