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
  {{- /* Also check sealedSecrets, at the ROOT and at component level.

         Both are collected into one list on purpose. A chart that declares its
         sealed secrets at the root (`common.sealedsecret (dict "Root" .)`, so
         `.Values.sealedSecrets`) and then renders its workloads with a
         per-component Config used to match NEITHER input: `$root.Values` has no
         `secrets`, and the component dict has no `sealedSecrets`. $secretsFound
         stayed empty, no checksum/secrets was emitted at all, and a reseal
         never rolled the pods.

         That drift is real and it is the invisible kind. On 2026-10-16 a
         resealed peer list and a narrowed AllowedIPs in apps/wireguard were
         live in git and reported Synced by ArgoCD while the running pods kept
         serving the old env, because env is read once at container start. They
         only picked it up after a manual rollout restart.

         When common.annotations is called with no Config, $config IS
         $root.Values, so the same entries are visited twice. Harmless: each one
         keys the same name to the same hash and takes the same scoping
         decision, so the result is identical.

         templateData holds ciphertext, which sealed-secrets regenerates on
         every seal, so resealing an UNCHANGED value also rolls the pods. That
         is the accepted cost of not parsing ciphertext we cannot decrypt, and
         resealing is a deliberate act anyway. */ -}}
  {{- $sealedEntries := list -}}
  {{- if kindIs "slice" $root.Values.sealedSecrets -}}
    {{- $sealedEntries = concat $sealedEntries $root.Values.sealedSecrets -}}
  {{- end -}}
  {{- if kindIs "slice" $config.sealedSecrets -}}
    {{- $sealedEntries = concat $sealedEntries $config.sealedSecrets -}}
  {{- end -}}
  {{- if kindIs "map" $root.Values.sealedSecret -}}
    {{- $sealedEntries = append $sealedEntries $root.Values.sealedSecret -}}
  {{- end -}}
  {{- range $secret := $sealedEntries -}}
    {{- if $secret.enabled -}}
      {{- $secretIncludeInChecksum := true -}}
      {{- if hasKey $secret "includeInChecksum" -}}
        {{- $secretIncludeInChecksum = $secret.includeInChecksum -}}
      {{- end -}}
      {{- /* Which controllers get it. An image pull credential, for one, is read
             at pull time, so rolling its holders on a reseal is pure churn. */ -}}
      {{- $includeChecksumInControllers := list -}}
      {{- if hasKey $secret "includeChecksumInControllers" -}}
        {{- $includeChecksumInControllers = $secret.includeChecksumInControllers -}}
      {{- end -}}
      {{- $secretChecksumAddToController := or (empty $includeChecksumInControllers) (has $comp $includeChecksumInControllers) -}}
      {{- if and $secretIncludeInChecksum $secretChecksumAddToController -}}
        {{- $key := $secret.name | default (include "common.fullname" $root) -}}
        {{- $_ := set $secretsFound $key (tpl (toYaml $secret.templateData) $root | sha256sum) -}}
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

{{- /*
  common.resolvedNodeSelector: the nodeSelector a workload should actually get.

  Returns the resolved map as YAML, always a map, so `{}` when there is none.
  Call sites run it through `fromYaml` and `with`, which skips an empty map:

    {{- with (include "common.resolvedNodeSelector" (dict "Root" $root "Config" $config) | fromYaml) }}
          nodeSelector:
            {{- toYaml . | nindent 12 }}
    {{- end }}

  An explicitly-set component nodeSelector wins, INCLUDING an empty map, which
  means "clear the chart-level pin and run anywhere". `default` and plain
  truthiness both read `{}` as unset and silently inherit the chart default, so
  a component that asked to be unpinned stayed pinned: verified 2026-10-16,
  `nodeSelector: {}` left all four adguard CronJobs on the worker. Only hasKey
  can tell "set to empty" apart from "not set".
*/ -}}
{{- define "common.resolvedNodeSelector" -}}
{{- $root := .Root -}}
{{- $config := .Config | default dict -}}
{{- if hasKey $config "nodeSelector" -}}
{{- toYaml ($config.nodeSelector | default dict) -}}
{{- else -}}
{{- toYaml ($root.Values.nodeSelector | default dict) -}}
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

{{- /*
  common.intValue — read an integer field off a Config dict with a fallback.

  `$config.field | default N` is wrong for any integer where 0 is a meaningful
  value: Helm's `default` treats 0 as empty, so `backoffLimit: 0` ("never
  retry") silently renders the default instead. This returns the configured
  value whenever the key is present and not null, and the fallback otherwise.

  Usage: {{ include "common.intValue" (dict "Config" $config "Key" "backoffLimit" "Default" 3) }}
*/}}
{{- define "common.intValue" -}}
{{- $config := .Config | default dict -}}
{{- $value := index $config .Key -}}
{{- if and (hasKey $config .Key) (not (kindIs "invalid" $value)) -}}
{{- $value -}}
{{- else -}}
{{- .Default -}}
{{- end -}}
{{- end -}}

{{- /*
  common.imageRef — build a container image reference from an image dict.

  Renders repository[:tag][@digest]. The digest is what actually pins the
  image: a tag is a moving pointer, and several upstreams (byparr, for one)
  publish nothing but `latest`, so without this there is no way to pin them
  and a chart silently redeploys whatever `latest` means today.

  Both parts are emitted when both are set. `repo:tag@sha256:...` is valid OCI
  and the digest wins, so the tag stays as human-readable documentation of
  what the digest resolved to.

  NOT named `common.image`, which looks like the obvious choice and is taken.
  Helm template names are global across a chart and every subchart, and the
  Bitnami-style `valkey` subchart vendored under immich defines its own
  `common.image` with a different signature (dict "image" ... "global" ...).
  Defining ours under that name silently hijacked valkey's calls and rendered
  `image: <nil>` in the immich release.

  Usage: image: {{ include "common.imageRef" $config.image | quote }}
*/}}
{{- define "common.imageRef" -}}
{{- $image := . | default dict -}}
{{- $ref := $image.repository | toString -}}
{{- if $image.tag -}}
{{- $ref = printf "%s:%s" $ref ($image.tag | toString) -}}
{{- end -}}
{{- if $image.digest -}}
{{- $ref = printf "%s@%s" $ref ($image.digest | toString) -}}
{{- end -}}
{{- $ref -}}
{{- end -}}
