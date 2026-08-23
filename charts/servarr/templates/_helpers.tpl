{{- /*
servarr.values — the effective values for one Servarr app.

Everything an app repeats is derived here from `app.name`, `app.uid` and
`app.port`: resource names, the NFS directory, the hostname and TLS secret, the
PUID/PGID env, the probe ports, the gatus endpoint. An app chart that wants
something else simply sets it — its own values are merged LAST and win, which is
how radarr keeps its node-local /config and its extra init container.
*/ -}}
{{- define "servarr.values" -}}
{{- $v := .Values -}}
{{- $app := $v.app | default dict -}}
{{- $name := $app.name | required "servarr: app.name is required (it names every resource, the NFS directory and the hostname)" -}}
{{- $uid := $app.uid | required "servarr: app.uid is required — unique per app, so a squashed NFS write cannot land as another app's user" | int -}}
{{- $port := $app.port | required "servarr: app.port is required" | int -}}
{{- $gid := $app.gid | default 100 | int -}}
{{- $title := $app.title | default ($name | title) -}}
{{- $probe := dict "path" "/" "port" $port -}}
{{- $volumeMounts := list (dict "name" "config" "mountPath" ($v.config).mountPath) -}}
{{- $volumes := list (dict "name" "config" "persistentVolumeClaim" (dict "claimName" (printf "%s-config-pvc" $name))) -}}
{{- $pvs := dict "config" (dict
      "enabled" true
      "name" (printf "%s-config-pv" $name)
      "pvcName" (printf "%s-config-pvc" $name)
      "storageClassName" (printf "%s-config" $name)
      "size" ($v.config).size
      "accessModes" (list "ReadWriteOnce")
      "mountOptions" ($v.config).mountOptions
      "nfs" (dict "server" $app.nfsServer "path" (printf "%s/%s" $app.configPath $name))) -}}
{{- /* The media tree is ReadWriteMany: shared with the download client and the
       other Servarr apps, so several writers hold it at once. */ -}}
{{- if ($v.media).enabled -}}
{{- $volumeMounts = append $volumeMounts (dict "name" "media" "mountPath" $v.media.mountPath) -}}
{{- $volumes = append $volumes (dict "name" "media" "persistentVolumeClaim" (dict "claimName" (printf "%s-media-pvc" $name))) -}}
{{- $_ := set $pvs "media" (dict
      "enabled" true
      "name" (printf "%s-media-pv" $name)
      "pvcName" (printf "%s-media-pvc" $name)
      "storageClassName" (printf "%s-media" $name)
      "size" $v.media.size
      "accessModes" (list "ReadWriteMany")
      "nfs" (dict "server" $app.nfsServer "path" $app.mediaPath)) -}}
{{- end -}}
{{- $host := printf "%s.%s" $name $app.domain -}}
{{- /* supplementalGroups: the shared NAS group only matters to the apps that
       mount the shared media tree. Prowlarr talks to indexers and never touches
       it, so it does not carry the group. */ -}}
{{- $derived := dict
    "fullnameOverride" $name
    "podSecurityContext" (merge
       (dict
         "fsGroup" $uid
         "fsGroupChangePolicy" "OnRootMismatch"
         "seccompProfile" (dict "type" "RuntimeDefault"))
       (ternary (dict "supplementalGroups" (list $gid)) dict (($v.media).enabled | default false)))
    "env" (dict "PUID" (printf "%d" $uid) "PGID" (printf "%d" $gid))
    "service" (dict "type" "ClusterIP" "port" $port "portName" "http" "targetPort" "http")
    "ingress" (dict
       "annotations" (dict "gatus.home-operations.com/endpoint" (printf "name: %s\ngroup: %s\nclient: { timeout: 30s }\nconditions: [\"[STATUS] < 500\"]\nalerts: [{ type: pushover }]\n" $title $app.gatusGroup))
       "hosts" (list (dict "host" $host "paths" (list (dict "path" "/" "pathType" "Prefix"))))
       "tlsSecretName" (printf "%s-tls" $name)
       "serviceName" (printf "%s-app" $name)
       "servicePort" $port)
    "probes" (dict
       "liveness" (dict "httpGet" $probe)
       "readiness" (dict "httpGet" $probe))
    "persistenceVolumes" $pvs
    "volumeMounts" $volumeMounts
    "volumes" $volumes
    "externalAuth" (dict
       "uid" $uid
       "gid" $gid
       "volumeMounts" (list (dict "name" "config" "mountPath" ($v.config).mountPath))) -}}
{{- /* The app's own values win: derived defaults first, then everything the
       chart and the app set on top. */ -}}
{{- $resolved := mergeOverwrite $derived (omit (deepCopy $v) "app" "config" "media") -}}
{{- /* The External-auth edit is an init container like any other, appended LAST
       so it has the final word on the auth mode: it patches config.xml, and a
       restore step running after it would put the old setting back. Rendered
       here rather than by the library -- common knows how to run an init
       container, not what a Servarr auth policy is. */ -}}
{{- $auth := $resolved.externalAuth | default dict -}}
{{- if $auth.enabled -}}
{{- $inits := concat ($resolved.initContainers | default list) (include "servarr.externalAuth" (dict "Config" $resolved "Auth" $auth) | fromYamlArray) -}}
{{- $_ := set $resolved "initContainers" $inits -}}
{{- end -}}
{{- toYaml $resolved -}}
{{- end -}}

{{- /* A Root context whose .Values are the resolved ones above, so the common
       helpers see exactly what a hand-written chart would have passed. */ -}}
{{- define "servarr.context" -}}
{{- $ctx := deepCopy . -}}
{{- $_ := set $ctx "Values" (include "servarr.values" . | fromYaml) -}}
{{- $ctx | toYaml -}}
{{- end -}}
