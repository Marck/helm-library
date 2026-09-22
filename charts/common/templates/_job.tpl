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
  backoffLimit: {{ include "common.intValue" (dict "Config" $config "Key" "backoffLimit" "Default" 3) }}
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
      {{- /* A pod that must survive node pressure — a per-node DNS cache, a
             metrics agent — needs a priorityClassName, or the kubelet evicts it
             like any other pod and everything depending on it fails while the
             cause looks unrelated. */}}
      {{- with (default $root.Values.priorityClassName $config.priorityClassName) }}
      priorityClassName: {{ . }}
      {{- end }}
      {{- /* Resolver overrides. dnsConfig with the default ClusterFirst policy
             APPENDS nameservers after the cluster resolver, so cluster names
             keep working and the extra entries act purely as a fallback --
             that is how an alert-sending Job still reaches its notification
             host when in-cluster DNS is degraded. A Job is the workload where
             this matters MOST: it runs once, and a Job that cannot resolve its
             notification host fails silently and tells nobody. */}}
      {{- /* hostNetwork on a batch workload: a Job that has to reach something
             published on the node's loopback (etcd's metrics port, say) cannot do it
             from the pod network at all. Long-running workloads have had this since
             the beginning; batch ones silently ignored it, so the values looked
             correct and the pod ran in the wrong namespace. */}}
      {{- if $config.hostNetwork }}
      hostNetwork: {{ $config.hostNetwork }}
      {{- end }}
      {{- /* hostNetwork implies ClusterFirstWithHostNet, or the pod keeps ClusterFirst
             while sharing the host's netns and resolves against the wrong servers. */}}
      {{- if or $config.dnsPolicy $config.hostNetwork }}
      dnsPolicy: {{ $config.dnsPolicy | default "ClusterFirstWithHostNet" }}
      {{- end }}
      {{- with $config.dnsConfig }}
      dnsConfig:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with (default $root.Values.podSecurityContext $config.podSecurityContext) }}
      securityContext:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with (default $root.Values.nodeSelector $config.nodeSelector) }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- /* Without tolerations a batch workload cannot be placed on a tainted node,
             so anything that must run ON the control plane was impossible. */}}
      {{- if or $config.tolerations $root.Values.tolerations }}
      tolerations:
        {{- toYaml (default $root.Values.tolerations $config.tolerations) | nindent 8 }}
      {{- end }}
      {{- with (default $root.Values.imagePullSecrets $config.imagePullSecrets) }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- $inits := include "common.initContainers" (dict "Root" $root "Config" $config) }}
      {{- if trim $inits }}
      initContainers:
      {{- $inits | trim | nindent 6 }}
      {{- end }}
      {{- if $config.containers }}
      containers:
        {{- toYaml $config.containers | nindent 8 }}
      {{- else if $config.image }}
      containers:
        - name: {{ $comp }}
          image: {{ include "common.imageRef" $config.image | quote }}
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
