{{- define "common.ingress" -}}
{{- $root := .Root }}
{{- /*
  Renders an Ingress. By default it reads $root.Values.ingress (unchanged, so all
  existing callers — dict "Root" . — behave identically). A chart that needs a
  SECOND ingress (e.g. a different host backed by a different service) can pass:
    Ingress      an alternative ingress config block (same shape as Values.ingress)
    NameSuffix   metadata.name suffix, so the two ingresses don't collide
                 (default "ingress" -> "<fullname>-ingress")
    ServiceName  backend service name   (default: Ingress.serviceName | "<fullname>-app")
    ServicePort  backend service port   (default: Ingress.servicePort | Values.service.port)
*/ -}}
{{- $ingress := .Ingress | default $root.Values.ingress }}
{{- $nameSuffix := .NameSuffix | default "ingress" }}
{{- $svcName := .ServiceName | default $ingress.serviceName | default (printf "%s-app" (include "common.fullname" $root)) }}
{{- /* `default` evaluates every arg, so guard against a nil Values.service when a
       second ingress targets a different service (ServicePort is passed explicitly). */ -}}
{{- $svcPort := .ServicePort | default $ingress.servicePort | default (($root.Values.service | default dict).port) }}
{{- if and $ingress $ingress.enabled }}
{{- /* Opt-in SSO policy check (no-op unless Values.sso.enforce) — an app that
       gets a public Ingress must say how it is authenticated. */ -}}
{{- include "common.sso.validate" (dict "Root" $root "Ingress" $ingress "NameSuffix" $nameSuffix) -}}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ include "common.fullname" $root }}-{{ $nameSuffix }}
  namespace: {{ $root.Values.namespace | default $root.Release.Namespace }}
  {{- if $ingress.annotations }}
  annotations:
{{- toYaml $ingress.annotations | nindent 4 }}
  {{- end }}
spec:
  {{- if $ingress.className }}
  ingressClassName: {{ $ingress.className | quote }}
  {{- end }}
  rules:
{{- range $host := $ingress.hosts }}
    - host: {{ $host.host }}
      http:
        paths:
{{- range $p := $host.paths }}
          - path: {{ $p.path }}
            pathType: {{ $p.pathType | default "Prefix" }}
            backend:
              service:
                name: {{ $svcName }}
                port:
                  number: {{ $svcPort }}
{{- end }}
{{- end }}
{{- if $ingress.tls }}
  tls:
    - secretName: {{ $ingress.tlsSecretName | default (printf "%s-cert" (include "common.fullname" $root)) }}
      hosts:
        {{- range $host := (required "ingress.hosts is required!" $ingress.hosts) }}
        - {{ printf "%s" (required "$host.host is required" $host.host) }}
        {{- end }}
{{- end }}
{{- end }}
{{- end }}
