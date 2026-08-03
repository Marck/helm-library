{{- /*
  common.sealedsecret — renders SealedSecrets from `sealedSecrets` (a list) or
  the legacy singular `sealedSecret`.

  Per entry:
    name / namespace / scope / type / templateData   as before
    template:                (optional) metadata for the Secret the controller
      labels: {}             UNSEALS — not for the SealedSecret itself. Needed
      annotations: {}        whenever something selects on the resulting Secret:
                             ArgoCD, for one, only treats a Secret as repository
                             credentials if it carries
                             `argocd.argoproj.io/secret-type: repo-creds`.

  common.labels and the sealing annotation are merged in LAST, so an entry can
  add metadata but cannot drop the chart's labels or re-scope its own sealing.
*/ -}}
{{- define "common.sealedsecret" -}}
{{- $root := .Root }}
{{- $config := .Config | default $root.Values }}
{{- if $config.sealedSecrets }}
{{- range $config.sealedSecrets }}
{{- if .enabled }}
{{- $scope := .scope | default "namespace-wide" }}
{{- $tmpl := .template | default dict }}
{{- $ownLabels := fromYaml (include "common.labels" $root) }}
{{- $extraLabels := dict }}
{{- range $k, $v := ($tmpl.labels | default dict) }}{{- if not (hasKey $ownLabels $k) }}{{- $_ := set $extraLabels $k $v }}{{- end }}{{- end }}
{{- $extraAnnotations := omit ($tmpl.annotations | default dict) (printf "sealedsecrets.bitnami.com/%s" $scope) }}
---
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: {{ .name | default (include "common.fullname" $root) }}
  namespace: {{ .namespace | default $root.Release.Namespace }}
  annotations:
    sealedsecrets.bitnami.com/{{ $scope }}: "true"
spec:
  encryptedData:
  {{- toYaml .templateData | nindent 4 }}
  template:
    type: {{ .type | default "Opaque" }}
    metadata:
      annotations:
        sealedsecrets.bitnami.com/{{ $scope }}: "true"
        {{- with $extraAnnotations }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      labels:
        {{- include "common.labels" $root | nindent 8 }}
        {{- with $extraLabels }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
{{- end }}
{{- end }}
{{- else if $root.Values.sealedSecret }}
{{- if $root.Values.sealedSecret.enabled }}
{{- $s := $root.Values.sealedSecret }}
{{- $scope := $s.scope | default "namespace-wide" }}
{{- $tmpl := $s.template | default dict }}
{{- $ownLabels := fromYaml (include "common.labels" $root) }}
{{- $extraLabels := dict }}
{{- range $k, $v := ($tmpl.labels | default dict) }}{{- if not (hasKey $ownLabels $k) }}{{- $_ := set $extraLabels $k $v }}{{- end }}{{- end }}
{{- $extraAnnotations := omit ($tmpl.annotations | default dict) (printf "sealedsecrets.bitnami.com/%s" $scope) }}
---
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: {{ $s.name | default (include "common.fullname" $root) }}
  namespace: {{ $root.Values.namespace | default $root.Release.Namespace }}
  annotations:
    sealedsecrets.bitnami.com/{{ $scope }}: "true"
spec:
  encryptedData:
  {{- toYaml $s.templateData | nindent 4 }}
  template:
    type: {{ $s.type | default "Opaque" }}
    metadata:
      annotations:
        sealedsecrets.bitnami.com/{{ $scope }}: "true"
        {{- with $extraAnnotations }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      labels:
        {{- include "common.labels" $root | nindent 8 }}
        {{- with $extraLabels }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
{{- end }}
{{- end }}
{{- end }}
