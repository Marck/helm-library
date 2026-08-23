{{- define "common.pv" -}}
{{- $root := .Root }}
{{- $comp := .Component | default "app" }}
{{- $config := .Config | default $root.Values }}

{{- /* Support for multiple PVs via persistenceVolumes */ -}}
{{- if $config.persistenceVolumes }}
{{- range $name, $pv := $config.persistenceVolumes }}
{{- if and $pv.enabled (not $pv.data) }}
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: {{ $pv.name | default (printf "%s-%s-pv" (include "common.fullname" $root) $name) }}
  labels:
{{- include "common.labels" $root | nindent 4 }}
spec:
  capacity:
    {{- /* pvCapacity, like the single-PV path below: a PV's capacity is immutable
           once bound, so a chart whose existing PV is larger than the claim it
           serves must be able to say both numbers rather than silently ask for a
           resize the API server will reject. */}}
    storage: {{ $pv.pvCapacity | default ($pv.size | required (printf "persistenceVolumes.%s.size is required" $name)) }}
  accessModes:
{{- range ($pv.accessModes | default (list "ReadWriteOnce")) }}
    - {{ . }}
{{- end }}
  {{- if $pv.reclaimPolicy}}
  persistentVolumeReclaimPolicy: {{ $pv.reclaimPolicy | quote }}
  {{- end }}
  {{- if $pv.storageClassName}}
  storageClassName: {{ $pv.storageClassName | quote }}
  {{- end }}
  {{- if $pv.nfs}}
  nfs:
    server: {{ $pv.nfs.server }}
    path: {{ $pv.nfs.path }}
  {{- end }}
  {{- if $pv.hostPath}}
  hostPath:
    path: {{ $pv.hostPath.path }}
    {{- if $pv.hostPath.type}}
    type: {{ $pv.hostPath.type }}
    {{- end }}
  {{- end }}
  {{- if $pv.local}}
  local:
    path: {{ $pv.local.path }}
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: {{ $pv.local.nodeAffinity.key | default "kubernetes.io/hostname" }}
          operator: In
          values:
          {{- range $pv.local.nodeAffinity.values }}
          - {{ . }}
          {{- end }}
  {{- end }}
  {{- if $pv.mountOptions }}
  mountOptions:
  {{- range $pv.mountOptions }}
    - {{ . }}
  {{- end }}
  {{- end }}
{{- end }}
{{- end }}
{{- else }}
{{- /* Backwards compatibility: single persistence object */ -}}
{{- $persistence := $config.persistence | default $root.Values.persistence }}
{{- if and (or $persistence.nfs $persistence.hostPath) (not $persistence.data) }}
apiVersion: v1
kind: PersistentVolume
metadata:
  name: {{ $persistence.name | default (printf "%s-%s-pv" (include "common.fullname" $root) $comp) }}
  labels:
{{- include "common.labels" $root | nindent 4 }}
spec:
  capacity:
    storage: {{ $persistence.pvCapacity | default ($persistence.size | required "persistence.size is required") }}
  accessModes:
{{- range ($persistence.accessModes | default (list "ReadWriteOnce")) }}
    - {{ . }}
{{- end }}
  {{- if $persistence.reclaimPolicy }}
  persistentVolumeReclaimPolicy: {{ $persistence.reclaimPolicy | quote }}
  {{- end }}
  {{- if $persistence.storageClassName }}
  storageClassName: {{ $persistence.storageClassName | quote }}
  {{- end }}
  {{- if $persistence.nfs }}
  nfs:
    server: {{ $persistence.nfs.server }}
    path: {{ $persistence.nfs.path }}
  {{- else if $persistence.hostPath }}
  hostPath:
    path: {{ $persistence.hostPath.path }}
    {{- if $persistence.hostPath.type }}
    type: {{ $persistence.hostPath.type }}
    {{- end }}
  {{- end }}
  {{- if $persistence.mountOptions }}
  mountOptions:
  {{- range $persistence.mountOptions }}
    - {{ . }}
  {{- end }}
  {{- end }}
{{- end }}
{{- end }}
{{- end }}
