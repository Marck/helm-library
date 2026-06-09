{{- define "common.networkPolicies" -}}
{{- $root := .Root -}}
{{- if $root.Values.networkPolicies -}}
{{- range $name, $policy := $root.Values.networkPolicies -}}
{{- if and $policy.enabled (or (kindIs "invalid" $root.Values.networkPoliciesEnabled) $root.Values.networkPoliciesEnabled) }}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: {{ $policy.name | default $name }}
  namespace: {{ $root.Values.namespace | default $root.Release.Namespace }}
  labels:
{{- include "common.labels" $root | nindent 4 }}
spec:
  podSelector:
    {{- if $policy.podSelector }}
    {{- toYaml $policy.podSelector | nindent 4 }}
    {{- else }}
    matchLabels: {}
    {{- end }}
  {{- if $policy.policyTypes }}
  policyTypes:
    {{- toYaml $policy.policyTypes | nindent 4 }}
  {{- end }}
  {{- if $policy.ingress }}
  ingress:
    {{- toYaml $policy.ingress | nindent 4 }}
  {{- end }}
  {{- if $policy.egress }}
  egress:
    {{- toYaml $policy.egress | nindent 4 }}
  {{- end }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
