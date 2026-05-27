{{- /* common helper templates */ -}}
{{- define "common.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride }}
{{- else }}
{{- printf "%s-%s" .Chart.Name .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end }}
{{- end }}

{{- define "common.labels" -}}
app.kubernetes.io/name: {{ include "common.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: Helm
{{- end }}

{{- /*
Returns the value for pod annotations with configmap and secret checksums
*/ -}}
{{- define "common.annotations" -}}
  {{- $root := .Root -}}
  {{- $comp := .Component | default "app" -}}
  {{- $config := .Config | default $root.Values -}}

  {{- /* Default annotations */ -}}
  {{- $annotations := dict -}}

  {{- /* Merge user-defined annotations if provided */ -}}
  {{- if $config.podAnnotations -}}
    {{- $annotations = merge $config.podAnnotations $annotations -}}
  {{- end -}}

  {{- /* Add configMaps checksum */ -}}
  {{- $configMapsFound := dict -}}
  {{- if $root.Values.configMaps -}}
    {{- range $name, $configmap := $root.Values.configMaps -}}
      {{- $configMapEnabled := true -}}
      {{- if hasKey $configmap "enabled" -}}
        {{- $configMapEnabled = $configmap.enabled -}}
      {{- end -}}
      {{- $configMapIncludeInChecksum := true -}}
      {{- if hasKey $configmap "includeInChecksum" -}}
        {{- $configMapIncludeInChecksum = $configmap.includeInChecksum -}}
      {{- end -}}
      {{- /* Check if this controller should get the checksum */ -}}
      {{- $includeChecksumInControllers := list -}}
      {{- if hasKey $configmap "includeChecksumInControllers" -}}
        {{- $includeChecksumInControllers = $configmap.includeChecksumInControllers -}}
      {{- end -}}
      {{- $configMapChecksumAddToController := or (empty $includeChecksumInControllers) (has $comp $includeChecksumInControllers) -}}
      {{- if and $configMapEnabled $configMapIncludeInChecksum $configMapChecksumAddToController -}}
        {{- $_ := set $configMapsFound $name (tpl (toYaml $configmap.data) $root | sha256sum) -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
  {{- /* Also check for component-level configmap */ -}}
  {{- if $config.configmap -}}
    {{- if $config.configmap.enabled -}}
      {{- $configMapIncludeInChecksum := true -}}
      {{- if hasKey $config.configmap "includeInChecksum" -}}
        {{- $configMapIncludeInChecksum = $config.configmap.includeInChecksum -}}
      {{- end -}}
      {{- if $configMapIncludeInChecksum -}}
        {{- $_ := set $configMapsFound (printf "%s-%s-configmap" (include "common.fullname" $root) $comp) (tpl (toYaml $config.configmap.data) $root | sha256sum) -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
  {{- if $configMapsFound -}}
    {{- $_ := set $annotations "checksum/configMaps" (toYaml $configMapsFound | sha256sum) -}}
  {{- end -}}

  {{- /* Add Secrets checksum */ -}}
  {{- $secretsFound := dict -}}
  {{- if $root.Values.secrets -}}
    {{- range $name, $secret := $root.Values.secrets -}}
      {{- $secretEnabled := true -}}
      {{- if hasKey $secret "enabled" -}}
        {{- $secretEnabled = $secret.enabled -}}
      {{- end -}}
      {{- $secretIncludeInChecksum := true -}}
      {{- if hasKey $secret "includeInChecksum" -}}
        {{- $secretIncludeInChecksum = $secret.includeInChecksum -}}
      {{- end -}}
      {{- /* Check if this controller should get the checksum */ -}}
      {{- $includeChecksumInControllers := list -}}
      {{- if hasKey $secret "includeChecksumInControllers" -}}
        {{- $includeChecksumInControllers = $secret.includeChecksumInControllers -}}
      {{- end -}}
      {{- $secretChecksumAddToController := or (empty $includeChecksumInControllers) (has $comp $includeChecksumInControllers) -}}
      {{- if and $secretEnabled $secretIncludeInChecksum $secretChecksumAddToController -}}
        {{- $_ := set $secretsFound $name (tpl (toYaml $secret.stringData) $root | sha256sum) -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
  {{- /* Also check for component-level sealedSecrets */ -}}
  {{- if $config.sealedSecrets -}}
    {{- range $secret := $config.sealedSecrets -}}
      {{- if $secret.enabled -}}
        {{- $secretIncludeInChecksum := true -}}
        {{- if hasKey $secret "includeInChecksum" -}}
          {{- $secretIncludeInChecksum = $secret.includeInChecksum -}}
        {{- end -}}
        {{- if $secretIncludeInChecksum -}}
          {{- $_ := set $secretsFound $secret.name (tpl (toYaml $secret.templateData) $root | sha256sum) -}}
        {{- end -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
  {{- if $secretsFound -}}
    {{- $_ := set $annotations "checksum/secrets" (toYaml $secretsFound | sha256sum) -}}
  {{- end -}}

  {{- if not (empty $annotations) -}}
    {{- $annotations | toYaml -}}
  {{- end -}}
{{- end -}}

{{- define "common.nodeSelector" -}}
{{- if .NodeSelector }}
nodeSelector:
{{ toYaml .NodeSelector | nindent 2 }}
{{- end }}
{{- end }}

{{- define "common.podSpecCommon" -}}
replicaCount: {{ .Values.replicaCount }}
{{- end }}
