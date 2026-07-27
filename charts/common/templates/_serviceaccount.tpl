{{- /*
  common.serviceaccount — renders a ServiceAccount when serviceAccount.create is true.

  Params:
    Root
    Config  (optional) — where serviceAccount is read from; defaults to root values
    Name    (optional) — explicit SA name, for a COMPONENT-scoped ServiceAccount that
                         only one workload uses (e.g. a hook Job that calls the API).
                         Without it the chart-wide common.serviceAccountName is used,
                         which every common.deployment in the chart also references —
                         so a chart needing RBAC for just one pod would otherwise have
                         to hand the SA to all of them. Pair with common.rbac's
                         ServiceAccountName and the job/cronjob Config serviceAccount.name.

  Values:
    serviceAccount:
      create: true
      name: ""              # defaults to common.fullname
      annotations: {}
      automount: true       # automountServiceAccountToken on the ServiceAccount
*/ -}}
{{- define "common.serviceaccount" -}}
{{- $root := .Root }}
{{- $config := .Config | default $root.Values }}
{{- $sa := $config.serviceAccount | default dict }}
{{- if $sa.create }}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ .Name | default (include "common.serviceAccountName" $root) }}
  namespace: {{ $root.Values.namespace | default $root.Release.Namespace }}
  labels:
{{- include "common.labels" $root | nindent 4 }}
  {{- with $sa.annotations }}
  annotations:
{{ toYaml . | indent 4 }}
  {{- end }}
automountServiceAccountToken: {{ if (kindIs "invalid" $sa.automount) }}true{{ else }}{{ $sa.automount }}{{ end }}
{{- end }}
{{- end }}

{{- /* Name of the ServiceAccount to use (also referenced by the deployment). */ -}}
{{- define "common.serviceAccountName" -}}
{{- $sa := .Values.serviceAccount | default dict }}
{{- if $sa.create }}
{{- $sa.name | default (include "common.fullname" .) }}
{{- else }}
{{- $sa.name | default "default" }}
{{- end }}
{{- end }}
