{{- define "common.ingress" -}}
{{- $root := .Root }}
{{- if and $root.Values.ingress $root.Values.ingress.enabled }}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ include "common.fullname" $root }}-ingress
  namespace: {{ $root.Values.namespace | default $root.Release.Namespace }}
  {{- if $root.Values.ingress.annotations }}
  annotations:
{{- toYaml $root.Values.ingress.annotations | nindent 4 }}
  {{- end }}
spec:
  {{- if $root.Values.ingress.className }}
  ingressClassName: {{ $root.Values.ingress.className | quote }}
  {{- end }}
  rules:
{{- range $host := $root.Values.ingress.hosts }}
    - host: {{ $host.host }}
      http:
        paths:
{{- range $p := $host.paths }}
          - path: {{ $p.path }}
            pathType: {{ $p.pathType | default "Prefix" }}
            backend:
              service:
                name: {{ $root.Values.ingress.serviceName | default (printf "%s-app" (include "common.fullname" $root)) }}
                port:
                  number: {{ $root.Values.ingress.servicePort | default $root.Values.service.port }}
{{- end }}
{{- end }}
{{- if $root.Values.ingress.tls }}
  tls:
    - secretName: {{ $root.Values.ingress.tlsSecretName | default (printf "%s-cert" (include "common.fullname" $root)) }}
      hosts:
        {{- range $host := (required "ingress.hosts is required!" $root.Values.ingress.hosts) }}
        - {{ printf "%s" (required "$host.host is required" $host.host) }}
        {{- end }}
{{- end }}
{{- end }}
{{- end }}
