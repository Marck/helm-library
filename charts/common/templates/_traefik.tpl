{{- /*
  Traefik custom resources, for the cases a Kubernetes Ingress cannot express:
  a middleware of the chart's own, or a route matched on more than host and
  path (a header, a query parameter, a priority).

  Both read a map keyed by a name of your choosing, like common.networkPolicies,
  and render nothing when the map is absent, so charts that do not use them are
  unaffected. Only the traefik.io API group is emitted: Traefik v3 serves no
  other.

  Strings are rendered through `tpl`, so a value may refer to another one, e.g.
  a host built from "{{ .Values.cluster.domain }}".
*/ -}}

{{- /*
  common.middlewares — one Middleware per enabled entry of Values.middlewares.

  values:
    middlewares:
      addPrefix:                  # key: the default metadata.name
        enabled: true
        name: add-prefix          # optional
        spec:                     # required: the Middleware spec, verbatim
          addPrefix:
            prefix: /api

  Reference it from an Ingress as <namespace>-<name>@kubernetescrd, or by name
  from an IngressRoute in the same namespace.
*/ -}}
{{- define "common.middlewares" -}}
{{- $root := .Root -}}
{{- range $key, $mw := ($root.Values.middlewares | default dict) -}}
{{- if $mw.enabled }}
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: {{ $mw.name | default $key }}
  namespace: {{ $root.Values.namespace | default $root.Release.Namespace }}
  labels:
{{- include "common.labels" $root | nindent 4 }}
spec:
{{- tpl (toYaml (required (printf "middlewares.%s.spec is required" $key) $mw.spec)) $root | nindent 2 }}
{{- end }}
{{- end }}
{{- end }}

{{- /*
  common.ingressRoutes — one IngressRoute per enabled entry of Values.ingressRoutes.

  values:
    ingressRoutes:
      oldClients:
        enabled: true
        name: old-clients         # optional
        entryPoints: [websecure]  # optional: all entry points when omitted
        routes:                   # required: the IngressRoute routes, verbatim
          - kind: Rule
            match: Host(`app.example.com`) && HeaderRegexp(`User-Agent`, `OldClient`)
            priority: 1000
            middlewares:
              - name: add-prefix
            services:
              - name: app
                port: 80
        tls: {}                   # optional. An empty map asks for the default
                                  # certificate; omit the key for plain HTTP.
*/ -}}
{{- define "common.ingressRoutes" -}}
{{- $root := .Root -}}
{{- range $key, $route := ($root.Values.ingressRoutes | default dict) -}}
{{- if $route.enabled }}
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: {{ $route.name | default $key }}
  namespace: {{ $root.Values.namespace | default $root.Release.Namespace }}
  labels:
{{- include "common.labels" $root | nindent 4 }}
spec:
  {{- with $route.entryPoints }}
  entryPoints:
{{- toYaml . | nindent 4 }}
  {{- end }}
  routes:
{{- tpl (toYaml (required (printf "ingressRoutes.%s.routes is required" $key) $route.routes)) $root | nindent 4 }}
  {{- if hasKey $route "tls" }}
  tls:
{{- tpl (toYaml ($route.tls | default dict)) $root | nindent 4 }}
  {{- end }}
{{- end }}
{{- end }}
{{- end }}
