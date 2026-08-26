{{- define "common.deployment" -}}
{{- $root := .Root }}
{{- $comp := .Component | default "app" }}
{{- $config := .Config | default $root.Values }}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "common.fullname" $root }}-{{ $comp }}
  namespace: {{ $root.Values.namespace | default $root.Release.Namespace }}
  {{- /* Annotations on the Deployment OBJECT (not the pod template) — e.g.
       argocd.argoproj.io/sync-wave to stagger rollouts of related workloads. */}}
  {{- with $config.deploymentAnnotations }}
  annotations:
{{ toYaml . | indent 4 }}
  {{- end }}
  labels:
{{- include "common.labels" $root | nindent 4 }}
spec:
  revisionHistoryLimit: {{ $config.revisionHistoryLimit | default 3 }}
  replicas: {{ if (kindIs "invalid" $config.replicaCount) }}1{{ else }}{{ $config.replicaCount }}{{ end }}
  strategy:
    type: {{ $config.strategy | default "Recreate" }}
    {{- if eq ($config.strategy | default "Recreate") "RollingUpdate" }}
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
      {{- /* A pod that must survive node pressure — a per-node DNS cache, a
             metrics agent — needs a priorityClassName, or the kubelet evicts it
             like any other pod and everything depending on it fails while the
             cause looks unrelated. */}}
      {{- with (default $root.Values.priorityClassName $config.priorityClassName) }}
      priorityClassName: {{ . }}
      {{- end }}
      {{- if $config.hostNetwork }}
      hostNetwork: {{ $config.hostNetwork }}
      {{- end }}
      {{- if or $config.dnsPolicy $config.hostNetwork }}
      dnsPolicy: {{ $config.dnsPolicy | default "ClusterFirstWithHostNet" }}
      {{- end }}
      {{- /* Extra resolver settings. With the default ClusterFirst policy these
             nameservers are APPENDED after the cluster resolver, so cluster
             names keep resolving and the entries act purely as a fallback. */}}
      {{- with $config.dnsConfig }}
      dnsConfig:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- /* Static /etc/hosts entries — e.g. pin an in-cluster hostname to a
           Service ClusterIP to avoid intermittent hairpin NAT on an OIDC
           back-channel. */}}
      {{- with (default $root.Values.hostAliases $config.hostAliases) }}
      hostAliases:
{{ toYaml . | indent 6 }}
      {{- end }}
      {{- /* Time the pod gets to shut down cleanly before SIGKILL. Raise it for
           workloads that must flush state on exit (databases, systemd-in-a-
           container); the 30s default truncates those. */}}
      {{- with (default $root.Values.terminationGracePeriodSeconds $config.terminationGracePeriodSeconds) }}
      terminationGracePeriodSeconds: {{ . }}
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
          {{- /* Allocate a TTY. Only needed by images whose PID 1 writes its
               startup output to /dev/console rather than stdout — systemd is the
               one that matters: without this its boot log, and the reason it
               exited, are simply not there. */}}
          {{- if $config.tty }}
          tty: {{ $config.tty }}
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
          {{- /* ports is optional — polling/batch workloads may expose no ports */ -}}
          {{- if or $config.ports $config.service }}
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
              {{- /* hostPort binds the port on the NODE — one pod per node, and a
                   collision leaves the pod Pending forever. Only for workloads a
                   Service cannot front (e.g. a loopback-only admin API). hostIP
                   narrows the bind, e.g. 127.0.0.1. */}}
              {{- if .hostPort }}
              hostPort: {{ .hostPort }}
              {{- end }}
              {{- if .hostIP }}
              hostIP: {{ .hostIP | quote }}
              {{- end }}
          {{- end }}
          {{- else if $config.service }}
            - containerPort: {{ $config.service.port | required "service.port is required when service is configured without ports" }}
              {{- if $config.service.portName }}
              name: {{ $config.service.portName }}
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
          {{- if $config.probes.startup }}
          {{- if $config.probes.startup.enabled }}
          startupProbe:
            {{- if $config.probes.startup.httpGet }}
            httpGet:
{{ toYaml $config.probes.startup.httpGet | indent 14 }}
            {{- else if $config.probes.startup.tcpSocket }}
            tcpSocket:
{{ toYaml $config.probes.startup.tcpSocket | indent 14 }}
            {{- else if $config.probes.startup.exec }}
            exec:
{{ toYaml $config.probes.startup.exec | indent 14 }}
            {{- else if $config.probes.startup.grpc }}
            grpc:
{{ toYaml $config.probes.startup.grpc | indent 14 }}
            {{- end }}
            initialDelaySeconds: {{ $config.probes.startup.initialDelaySeconds | default 0 }}
            periodSeconds: {{ $config.probes.startup.periodSeconds | default 10 }}
            timeoutSeconds: {{ $config.probes.startup.timeoutSeconds | default 1 }}
            failureThreshold: {{ $config.probes.startup.failureThreshold | default 3 }}
          {{- end }}
          {{- end }}
          {{- end }}
          {{- if $config.resources }}
          resources:
{{ toYaml $config.resources | indent 12 }}
          {{- end }}
          {{- /* Container lifecycle hooks (postStart / preStop). postStart runs
               CONCURRENTLY with the entrypoint — never assume the app is up. A
               failing hook kills the container, so keep the command idempotent
               (it re-runs on every restart). */}}
          {{- with $config.lifecycle }}
          lifecycle:
{{ tpl (toYaml .) $root | indent 12 }}
          {{- end }}
          {{- if or $config.volumeMounts (or $config.persistence $root.Values.persistence) }}
          volumeMounts:
          {{- if $config.volumeMounts }}
{{ tpl (toYaml $config.volumeMounts) $root | indent 12 }}
          {{- else if or $config.persistence $root.Values.persistence }}
            - name: data
              mountPath: /data
          {{- end }}
          {{- end }}
      {{- if $config.additionalContainers }}
{{ toYaml $config.additionalContainers | indent 8 }}
      {{- end }}
      {{- if or $config.volumes (or $config.persistence $root.Values.persistence) }}
      volumes:
      {{- if $config.volumes }}
{{ tpl (toYaml $config.volumes) $root | indent 8 }}
      {{- else if or $config.persistence $root.Values.persistence }}
        - name: data
          persistentVolumeClaim:
            claimName: {{ include "common.fullname" $root }}-{{ $comp }}-pvc
      {{- end }}
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
{{- end }}
