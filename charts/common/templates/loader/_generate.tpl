{{- /* Loader template to generate resources based on values */ -}}
{{- /* TODO: fix this to load everything and use it if the values.yaml of the parent chart dictates it */ -}}

{{- define "common.loader.generate" -}}
{{- $commonValues := .Values.common | default .Values -}}
{{- $root := merge (dict "Values" $commonValues) . -}}
{{- $ctx := dict "Root" $root "Release" .Release "Capabilities" .Capabilities -}}

{{ include "common.configmap" $ctx }}
---
{{ include "common.deployment" $ctx }}
---
{{ include "common.ingress" $ctx }}
---
{{ include "common.pv" $ctx }}
---
{{ include "common.pvc" $ctx }}
---
{{ include "common.sealedsecret" $ctx }}
---
{{ include "common.service" $ctx }}
---
{{ include "common.serviceaccount" $ctx }}
---
{{ include "common.rbac" $ctx }}
{{- end -}}
