{{- /*
  common.rbac — renders a (Cluster)Role and a matching (Cluster)RoleBinding to the
  chart's ServiceAccount. Namespaced Role/RoleBinding is used unless clusterWide: true.

  Values:
    rbac:
      create: true
      clusterWide: false    # true -> ClusterRole + ClusterRoleBinding
      name: ""              # defaults to common.fullname
      rules: []             # standard rbac rules
*/ -}}
{{- define "common.rbac" -}}
{{- $root := .Root }}
{{- $config := .Config | default $root.Values }}
{{- $rbac := $config.rbac | default dict }}
{{- if $rbac.create }}
{{- $name := $rbac.name | default (include "common.fullname" $root) }}
{{- $namespace := $root.Values.namespace | default $root.Release.Namespace }}
apiVersion: rbac.authorization.k8s.io/v1
kind: {{ if $rbac.clusterWide }}ClusterRole{{ else }}Role{{ end }}
metadata:
  name: {{ $name }}
  {{- if not $rbac.clusterWide }}
  namespace: {{ $namespace }}
  {{- end }}
  labels:
{{- include "common.labels" $root | nindent 4 }}
rules:
{{ toYaml ($rbac.rules | default list) | indent 2 }}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: {{ if $rbac.clusterWide }}ClusterRoleBinding{{ else }}RoleBinding{{ end }}
metadata:
  name: {{ $name }}
  {{- if not $rbac.clusterWide }}
  namespace: {{ $namespace }}
  {{- end }}
  labels:
{{- include "common.labels" $root | nindent 4 }}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: {{ if $rbac.clusterWide }}ClusterRole{{ else }}Role{{ end }}
  name: {{ $name }}
subjects:
  - kind: ServiceAccount
    name: {{ include "common.serviceAccountName" $root }}
    namespace: {{ $namespace }}
{{- end }}
{{- end }}
