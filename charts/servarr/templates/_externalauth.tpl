{{- /*
servarr.externalAuth — put a Servarr app behind the SSO proxy, safely.

Why this exists
---------------
Sonarr, Radarr, Lidarr and Prowlarr authenticate through the forward-auth proxy,
which means `AuthenticationMethod=External` in config.xml. The app writes that
file itself and does not read the setting from the environment, so each chart
carried an init container that edited the XML before start -- four copies of the
same 25-line shell script, differing only in the uid and a comment's wrapping.

Four copies is four places to fix when the logic is wrong, and this logic is
security-relevant: get it wrong and the app comes up with no authentication at
all, reachable through an Ingress. So it lives once -- HERE, in the chart that
knows what a Servarr app is. It is deliberately not in `common`: the library
holds shapes any chart can use (a Deployment, a CronJob, a chown), not one
application family's authentication policy.

What it does, in order:
  * no config.xml yet (first boot): write one containing only the two auth
    elements -- the app fills in ApiKey, Port and the rest on start;
  * config.xml exists with an AuthenticationMethod: rewrite it to External;
  * config.xml exists without one: insert it before </Config>;
  * then VERIFY, and exit non-zero if the file does not now say External. An
    unverified pass here would start an unexpectedly open app.

    externalAuth:
      enabled: true
      configPath: /config/config.xml   # default
      image: busybox:1.38              # pin it

The uid comes from the workload's own securityContext, so the file it writes
belongs to the app that has to read it.
*/ -}}
{{- define "servarr.externalAuth" -}}
{{- $config := .Config | default dict -}}
{{- $a := .Auth | default dict -}}
{{- $cfg := $a.configPath | default "/config/config.xml" -}}
{{- $psc := $config.podSecurityContext | default dict -}}
{{- $csc := $config.securityContext | default dict -}}
{{- $uid := $a.uid | default $psc.runAsUser | default $csc.runAsUser -}}
{{- $gid := $a.gid | default $psc.runAsGroup | default $csc.runAsGroup -}}
{{- /* This container WRITES config.xml, so the file it creates must belong to the
       app that has to read and rewrite it afterwards. The linuxserver-style
       charts carry their uid in PUID/PGID env vars, which nothing here can read,
       so there is genuinely nothing to infer -- and silently falling back to root
       would leave a root-owned config.xml the app cannot rewrite. Say so. */ -}}
{{- if kindIs "invalid" $uid -}}
{{- fail "servarr.externalAuth: no uid — set externalAuth.uid (PUID-style charts have nothing for it to inherit), or the config.xml it writes will be owned by root" -}}
{{- end -}}
- name: {{ $a.name | default "set-external-auth" }}
  image: {{ $a.image | default "busybox:1.38" | quote }}
  imagePullPolicy: {{ $a.pullPolicy | default "IfNotPresent" }}
  command:
    - /bin/sh
    - -c
    - |
      set -eu
      CFG={{ $cfg }}
      if [ ! -f "$CFG" ]; then
        # First boot: the app has not written its config yet. Seed just the two
        # auth elements — it fills in ApiKey, Port and the rest itself.
        printf '%s\n' '<Config>' \
          '  <AuthenticationMethod>External</AuthenticationMethod>' \
          '  <AuthenticationRequired>Enabled</AuthenticationRequired>' \
          '</Config>' > "$CFG"
        echo "seeded $CFG with AuthenticationMethod=External"
        exit 0
      fi
      if grep -q '<AuthenticationMethod>' "$CFG"; then
        sed -i 's|<AuthenticationMethod>[^<]*</AuthenticationMethod>|<AuthenticationMethod>External</AuthenticationMethod>|' "$CFG"
      else
        sed -i 's|</Config>|  <AuthenticationMethod>External</AuthenticationMethod>\n</Config>|' "$CFG"
      fi
      # Fail loudly rather than starting an unexpectedly open app.
      grep -q '<AuthenticationMethod>External</AuthenticationMethod>' "$CFG"
      echo "AuthenticationMethod=External"
  securityContext:
    {{- if $a.securityContext }}
    {{- toYaml $a.securityContext | nindent 4 }}
    {{- else }}
    allowPrivilegeEscalation: false
    {{- if not (kindIs "invalid" $uid) }}
    runAsNonRoot: {{ ne (int $uid) 0 }}
    runAsUser: {{ int $uid }}
    {{- end }}
    {{- if not (kindIs "invalid" $gid) }}
    runAsGroup: {{ int $gid }}
    {{- end }}
    readOnlyRootFilesystem: true
    capabilities:
      drop:
        - ALL
    seccompProfile:
      type: RuntimeDefault
    {{- end }}
  {{- with $a.resources }}
  resources:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  volumeMounts:
    {{- toYaml ($a.volumeMounts | required "servarr.externalAuth: volumeMounts must mount the volume holding config.xml") | nindent 4 }}
{{- end -}}
