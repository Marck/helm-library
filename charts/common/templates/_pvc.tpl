{{- define "common.pvc" -}}
{{- $root := .Root }}
{{- $comp := .Component | default "app" }}
{{- $config := .Config | default $root.Values }}

{{- /* Support for multiple PVCs via persistenceVolumes */ -}}
{{- if $config.persistenceVolumes }}
{{- range $name, $pv := $config.persistenceVolumes }}
{{- if $pv.enabled }}
{{- $pvcName := "" }}
{{- if $pv.pvcName }}
  {{- $pvcName = $pv.pvcName }}
{{- else if $pv.name }}
  {{- $pvcName = regexReplaceAll "-pv$" $pv.name "-pvc" }}
  {{- if not (hasSuffix "-pvc" $pvcName) }}
    {{- $pvcName = printf "%s-pvc" $pv.name }}
  {{- end }}
{{- else }}
  {{- $pvcName = printf "%s-%s-pvc" (include "common.fullname" $root) $name }}
{{- end }}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ $pvcName }}
  namespace: {{ $root.Values.namespace | default $root.Release.Namespace }}
  labels:
{{- include "common.labels" $root | nindent 4 }}
spec:
  accessModes:
{{- if $pv.data }}
    - {{ $pv.data.accessMode | default "ReadWriteOnce" }}
{{- else }}
{{- range ($pv.accessModes | default (list "ReadWriteOnce")) }}
    - {{ . }}
{{- end }}
{{- end }}
  resources:
    requests:
{{- if $pv.data }}
      storage: {{ $pv.data.size | required (printf "persistenceVolumes.%s.data.size is required" $name) }}
{{- else }}
      storage: {{ $pv.size | required (printf "persistenceVolumes.%s.size is required" $name) }}
{{- end }}
  {{- if $pv.data }}
  {{- if $pv.data.storageClass }}
  storageClassName: {{ $pv.data.storageClass | quote }}
  {{- end }}
  {{- else if $pv.storageClassName }}
  storageClassName: {{ $pv.storageClassName | quote }}
  {{- end }}
  {{- if and $pv.nfs (not $pv.data) }}
  volumeName: {{ $pv.name | default (printf "%s-%s-pv" (include "common.fullname" $root) $name) }}
  {{- end }}
{{- end }}
{{- end }}
{{- else }}
{{- /* Backwards compatibility: single persistence object */ -}}
{{- $persistence := $config.persistence | default $root.Values.persistence }}
{{- $pvcName := "" }}
{{- if $persistence.pvcName }}
  {{- $pvcName = $persistence.pvcName }}
{{- else if $persistence.name }}
  {{- $pvcName = regexReplaceAll "-pv$" $persistence.name "-pvc" }}
  {{- if not (hasSuffix "-pvc" $pvcName) }}
    {{- $pvcName = printf "%s-pvc" $persistence.name }}
  {{- end }}
{{- else }}
  {{- $pvcName = printf "%s-%s-pvc" (include "common.fullname" $root) $comp }}
{{- end }}
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ $pvcName }}
  namespace: {{ $root.Values.namespace | default $root.Release.Namespace }}
  labels:
{{- include "common.labels" $root | nindent 4 }}
spec:
  accessModes:
{{- if $persistence.data }}
    - {{ $persistence.data.accessMode | default "ReadWriteOnce" }}
{{- else }}
{{- range ($persistence.accessModes | default (list "ReadWriteOnce")) }}
    - {{ . }}
{{- end }}
{{- end }}
  resources:
    requests:
{{- if $persistence.data }}
      storage: {{ $persistence.data.size | required "persistence.data.size is required" }}
{{- else }}
      storage: {{ $persistence.size | required "persistence.size is required" }}
{{- end }}
  {{- if $persistence.data }}
  {{- if $persistence.data.storageClass }}
  storageClassName: {{ $persistence.data.storageClass | quote }}
  {{- end }}
  {{- else if $persistence.storageClassName }}
  storageClassName: {{ $persistence.storageClassName | quote }}
  {{- end }}
  {{- if and $persistence.nfs (not $persistence.data) }}
  volumeName: {{ $persistence.name | default (printf "%s-%s-pv" (include "common.fullname" $root) $comp) }}
  {{- end }}
{{- end }}
{{- end }}
