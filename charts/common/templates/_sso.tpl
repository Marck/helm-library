{{- /*
  common.sso.validate — assert that a chart exposing an Ingress has *declared*
  how it is authenticated, so a new app can't quietly ship without SSO.

  OPT-IN: does nothing unless `.Values.sso.enforce` is true. Charts that don't
  set an `sso` block (or set enforce: false) render exactly as before, so this
  is safe for any consumer that doesn't want the policy.

  This helper is deliberately provider-agnostic — it validates the DECLARATION,
  not the wiring. It knows nothing about any particular identity provider; a
  repo that wants to check the declaration against reality (does the IdP really
  have a client for this app? is the middleware really on the Ingress?) should
  do that in CI, where it can see all charts at once.

  values:
    sso:
      enforce: true             # opt in to the checks below
      mode: oidc                # required: how this app authenticates
      reason: ""                # required when mode is "none": WHY it is exempt
      allowedModes: []          # optional: override the accepted modes
      forwardAuthMarker: ""     # optional: substring that must appear in the
                                # Ingress annotations when mode is forward-auth
                                # (e.g. the edge-auth middleware reference)

  Called automatically by common.ingress. Charts whose Ingress comes from an
  upstream subchart can invoke it directly:
    {{ include "common.sso.validate" (dict "Root" .) }}
*/ -}}
{{- define "common.sso.validate" -}}
{{- $root := .Root -}}
{{- $sso := $root.Values.sso | default dict -}}
{{- if $sso.enforce -}}
{{-   $chart := $root.Chart.Name -}}
{{-   $allowed := $sso.allowedModes | default (list "oidc" "forward-auth" "none") -}}
{{-   $mode := $sso.mode | default "" -}}
{{-   if not $mode -}}
{{-     fail (printf "common.sso: chart %q exposes an Ingress but declares no sso.mode. Set one of [%s] under `sso:` in values.yaml — use `mode: none` with a `reason:` if this app is deliberately not behind SSO." $chart (join " " $allowed)) -}}
{{-   end -}}
{{-   if not (has $mode $allowed) -}}
{{-     fail (printf "common.sso: chart %q has invalid sso.mode %q — allowed: [%s]" $chart $mode (join " " $allowed)) -}}
{{-   end -}}
{{-   if eq $mode "none" -}}
{{-     if not (trim ($sso.reason | default "")) -}}
{{-       fail (printf "common.sso: chart %q sets sso.mode: none but no sso.reason. Record WHY this app stays on its own auth, so the exemption is reviewable." $chart) -}}
{{-     end -}}
{{-   end -}}
{{-   if eq $mode "forward-auth" -}}
{{-     $marker := $sso.forwardAuthMarker | default "" -}}
{{-     if $marker -}}
{{-       $ing := .Ingress | default $root.Values.ingress | default dict -}}
{{-       $ann := toYaml ($ing.annotations | default dict) -}}
{{-       if not (contains $marker $ann) -}}
{{-         fail (printf "common.sso: chart %q declares sso.mode: forward-auth but its Ingress annotations do not reference %q — the declaration and the Ingress disagree." $chart $marker) -}}
{{-       end -}}
{{-     end -}}
{{-   end -}}
{{- end -}}
{{- end -}}
