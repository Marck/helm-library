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
    - hosts:
        {{- range $host := (required "ingress.hosts is required!" $ingress.hosts) }}
        - {{ printf "%s" (required "$host.host is required" $host.host) }}
        {{- end }}
      {{- /*
        secretName is emitted ONLY when the chart asks for one. It used to default
        to "<fullname>-cert", which named a Secret that in practice did not exist:
        once a cluster serves one wildcard certificate through Traefik's default
        TLSStore, no app keeps a per-host Secret. The Ingress still advertised the
        missing name, so Traefik logged
          Error configuring TLS: secret <ns>/<name>-tls does not exist
        for EVERY such ingress on every config reload. Serving was unaffected (the
        default certificate takes over), which is what let 30 of them accumulate
        unnoticed, and that volume of ERROR is exactly what hides a real one.
        A tls block with hosts and no secretName is the documented way to say
        "serve TLS with the default certificate"; verified against a live Traefik,
        which served the wildcard with a chain that validates (ssl_verify_result 0).
        A chart that genuinely owns a certificate still sets tlsSecretName.
      */}}
      {{- with $ingress.tlsSecretName }}
      secretName: {{ . }}
      {{- end }}
{{- end }}
{{- end }}
{{- end }}
