{{- /*
  common.keepalived: a LAN address held over VRRP by keepalived, one hostNetwork
  pod per node, with no Kubernetes object in the traffic path. The app serves on
  a hostPort; whichever node holds the address answers it.

    {{ include "common.keepalived" (dict "Root" . "Config" .Values.keepalived) }}

  Renders a ConfigMap and a DaemonSet named <fullname>-<Component> (Component
  defaults to "keepalived"). Config keys (see the defaults below):

    vip                  the address; rendered through tpl, so it may reference
                         values ("{{ .Values.cluster.dnsVIP }}")
    virtualRouterId      unique per LAN segment and per address group
    instanceName         VRRP instance name in logs (default VI_<id>)
    advertInt, garpMasterRefresh
    preferredNodeIP      node (status.hostIP) that gets priorityPreferred; every
    priorityPreferred    other node gets priorityOther. Empty: all equal.
    priorityOther
    track                optional health check, run by keepalived every interval:
      name               vrrp_script name in logs (default "track")
      script             path inside the image
      env                extra env for the script (values tpl'd); TRACK_TARGET
                         is always the node's own IP
      interval, timeout, fall, rise
      weight             MUST be negative: 0 puts a failing node in FAULT,
                         which drops the address
    extraTracks          more checks, each its own vrrp_script with the keys of
                         `track` except env, same weight rule. A script gets its
                         own variables on the command line:
                         "/usr/bin/env QUERY_NAME=x EXPECT_ANSWER= /path/check.sh"
    drain                optional, makes planned restarts of the app lossless:
      weight             penalty while the app on this node drains; must sit
                         between the priority gap and each track's |weight|
                         minus it (the render fails otherwise)
      hostPath           node directory shared with the app pod (default
                         /run/keepalived-drain/<fullname>, tmpfs, gone on reboot)
                         The app mounts the same directory and writes "1" to
                         <dir>/flag in its preStop, then keeps serving for a
                         few seconds while the address moves; it writes "0"
                         once its old instance has been gone long enough for
                         the track check to have failed. keepalived reads the
                         file through inotify (track_file), so there is no
                         polling delay.
    image, imagePullSecrets, resources, nodeSelector, tolerations, ...
                         as for common.daemonset

  Built from the adguard DNS VIP (helm-charts task #482). The defaults carry what
  that cost to learn:
    * SETGID: keepalived calls setgroups() before every track script. Without
      the capability the child exits 0 and every check "succeeds" forever.
    * nodeSelector {}: absent inherits the chart's, and a pair with one member
      is no failover.
    * OnDelete: one template change must not restart every holder at once.
    * keepalived removes its addresses at startup, so never first-start it on
      a node where something else (kube-vip) holds the same address.
    * A track_file on a read-only mount is dropped with only a warning ("track
      file ... not found, ignoring") and the instance runs without it, so the
      drain directory is mounted read-write and the render init container
      fails on any check keepalived ignores.
*/ -}}
{{- define "common.keepalived" -}}
{{- $root := .Root }}
{{- $comp := .Component | default "keepalived" }}
{{- $name := printf "%s-%s" (include "common.fullname" $root) $comp }}
{{- $defaults := dict
      "virtualRouterId" 51
      "instanceName" ""
      "advertInt" 1
      "garpMasterRefresh" 60
      "preferredNodeIP" ""
      "priorityPreferred" 110
      "priorityOther" 100
      "hostNetwork" true
      "updateStrategy" "OnDelete"
      "automountServiceAccountToken" false
      "nodeSelector" dict
      "tolerations" (list (dict "operator" "Exists"))
      "resources" (dict
        "requests" (dict "cpu" "10m" "memory" "32Mi")
        "limits" (dict "memory" "64Mi"))
      "podSecurityContext" (dict "seccompProfile" (dict "type" "RuntimeDefault"))
      "securityContext" (dict
        "allowPrivilegeEscalation" false
        "readOnlyRootFilesystem" true
        "capabilities" (dict
          "drop" (list "ALL")
          "add" (list "NET_ADMIN" "NET_RAW" "SETGID"))) }}
{{- $ka := mergeOverwrite $defaults (deepCopy .Config) }}
{{- if not $ka.vip }}{{ fail "common.keepalived: Config.vip is required" }}{{ end }}
{{- with $ka.track }}
{{- if ge (int .weight) 0 }}{{ fail "common.keepalived: track.weight must be negative; 0 or more sends a failing node to FAULT, which drops the address" }}{{ end }}
{{- end }}
{{- $names := list }}
{{- with $ka.track }}{{ $names = append $names (.name | default "track") }}{{ end }}
{{- range $i, $t := ($ka.extraTracks | default list) }}
{{- if not (and $t.name $t.script) }}{{ fail (printf "common.keepalived: extraTracks[%d] needs a name and a script" $i) }}{{ end }}
{{- if has $t.name $names }}{{ fail (printf "common.keepalived: track name %s is used twice" $t.name) }}{{ end }}
{{- $names = append $names $t.name }}
{{- if ge (int $t.weight) 0 }}{{ fail (printf "common.keepalived: extraTracks %s: weight must be negative; 0 or more sends a failing node to FAULT, which drops the address" $t.name) }}{{ end }}
{{- end }}
{{- with $ka.drain }}
{{- $w := int .weight }}
{{- $gap := 0 }}
{{- if $ka.preferredNodeIP }}{{ $gap = sub (int $ka.priorityPreferred) (int $ka.priorityOther) }}{{ end }}
{{- if ge $w 0 }}{{ fail "common.keepalived: drain.weight must be negative" }}{{ end }}
{{- if le (sub 0 $w) $gap }}{{ fail (printf "common.keepalived: drain.weight %d leaves a draining preferred node above a healthy one; its size must exceed the priority gap (%d)" $w $gap) }}{{ end }}
{{- with $ka.track }}
{{- if ge (sub 0 $w) (sub (sub 0 (int .weight)) $gap) }}{{ fail (printf "common.keepalived: drain.weight %d puts a draining node (still serving) below one whose track failed; its size must stay under |track.weight| minus the priority gap (%d)" $w (sub (sub 0 (int .weight)) $gap)) }}{{ end }}
{{- end }}
{{- range ($ka.extraTracks | default list) }}
{{- if ge (sub 0 $w) (sub (sub 0 (int .weight)) $gap) }}{{ fail (printf "common.keepalived: drain.weight %d puts a draining node (still serving) below one whose %s check failed; its size must stay under that |weight| minus the priority gap (%d)" $w .name (sub (sub 0 (int .weight)) $gap)) }}{{ end }}
{{- end }}
{{- $_ := set $ka.drain "hostPath" (.hostPath | default (printf "/run/keepalived-drain/%s" (include "common.fullname" $root))) }}
{{- end }}
{{- $conf := include "common.keepalived.conf" (dict "Root" $root "Config" $ka) }}
{{- $render := include "common.keepalived.render" . }}
{{ include "common.configmap" (dict "Root" $root "Name" $name "Data" (dict
      "keepalived.conf" $conf
      "keepalived-render.sh" $render)) }}
---
{{- $nodeIP := dict "valueFrom" (dict "fieldRef" (dict "fieldPath" "status.hostIP")) }}
{{- $env := dict }}
{{- if or $ka.track $ka.extraTracks }}
{{- $_ := set $env "TRACK_TARGET" $nodeIP }}
{{- end }}
{{- with $ka.track }}
{{- range $k, $v := (.env | default dict) }}
{{- $_ := set $env $k (tpl (toString $v) $root) }}
{{- end }}
{{- end }}
{{- $_ := set $ka "env" $env }}
{{- $image := printf "%s:%s" $ka.image.repository (toString $ka.image.tag) }}
{{- /* Read-write on purpose: keepalived ignores a track_file on a read-only
       filesystem. The render init container mounts it too, so its config test
       sees the same file system. */}}
{{- $drainMount := list }}
{{- $drainVolume := list }}
{{- with $ka.drain }}
{{- $drainMount = list (dict "name" "drain" "mountPath" "/drain") }}
{{- $drainVolume = list (dict "name" "drain" "hostPath" (dict "path" .hostPath "type" "DirectoryOrCreate")) }}
{{- end }}
{{- $_ := set $ka "initContainers" (list (dict
      "name" "render"
      "image" $image
      "imagePullPolicy" ($ka.image.pullPolicy | default "IfNotPresent")
      "command" (list "/bin/sh" "/template/keepalived-render.sh")
      "env" (list
        (dict "name" "NODE_IP" "valueFrom" $nodeIP.valueFrom)
        (dict "name" "PREFERRED_NODE_IP" "value" (toString $ka.preferredNodeIP))
        (dict "name" "PRIORITY_PREFERRED" "value" (toString $ka.priorityPreferred))
        (dict "name" "PRIORITY_OTHER" "value" (toString $ka.priorityOther)))
      "resources" $ka.resources
      "securityContext" (dict
        "allowPrivilegeEscalation" false
        "readOnlyRootFilesystem" true
        "capabilities" (dict "drop" (list "ALL")))
      "volumeMounts" (concat (list
        (dict "name" "template" "mountPath" "/template" "readOnly" true)
        (dict "name" "config" "mountPath" "/etc/keepalived")) $drainMount))) }}
{{- $_ := set $ka "volumeMounts" (concat (list
      (dict "name" "config" "mountPath" "/etc/keepalived" "readOnly" true)
      (dict "name" "run" "mountPath" "/run")) $drainMount) }}
{{- $_ := set $ka "volumes" (concat (list
      (dict "name" "template" "configMap" (dict "name" $name))
      (dict "name" "config" "emptyDir" (dict "medium" "Memory" "sizeLimit" "1Mi"))
      (dict "name" "run" "emptyDir" (dict "medium" "Memory" "sizeLimit" "1Mi"))) $drainVolume) }}
{{- $_ := set $ka "podAnnotations" (merge (dict "checksum/keepalived" (cat $render $conf | sha256sum)) ($ka.podAnnotations | default dict)) }}
{{ include "common.daemonset" (dict "Root" $root "Component" $comp "Config" $ka) }}
{{- end }}

{{- /* keepalived.conf, still holding @IFACE@ and @PRIORITY@ for the per-node
       render. */ -}}
{{- define "common.keepalived.conf" -}}
{{- $root := .Root }}
{{- $ka := .Config -}}
global_defs {
    # Scripts must be root-owned and not writable by others, or keepalived
    # skips them.
    enable_script_security
    script_user root
    # No realtime scheduling: that needs CAP_SYS_NICE.
    max_auto_priority -1
}
{{ with $ka.track }}
vrrp_script {{ .name | default "track" }} {
    script "{{ .script }}"
    interval {{ .interval | default 2 }}
    timeout {{ .timeout | default 2 }}
    fall {{ .fall | default 3 }}
    rise {{ .rise | default 2 }}
    # Negative: a failing node is demoted, never FAULT.
    weight {{ .weight }}
    # A starting node counts as failed until its check passes once.
    init_fail
}
{{ end }}
{{- range $ka.extraTracks }}
vrrp_script {{ .name }} {
    script "{{ .script }}"
    interval {{ .interval | default 2 }}
    timeout {{ .timeout | default 2 }}
    fall {{ .fall | default 3 }}
    rise {{ .rise | default 2 }}
    weight {{ .weight }}
    init_fail
}
{{ end }}
{{- with $ka.drain }}
track_file drain {
    # The app on this node writes 1 before it stops and 0 once it is safe
    # again; keepalived picks the change up through inotify.
    file "/drain/flag"
    weight {{ .weight }}
}
{{ end }}
vrrp_instance {{ $ka.instanceName | default (printf "VI_%v" $ka.virtualRouterId) }} {
    state BACKUP
    interface @IFACE@
    virtual_router_id {{ $ka.virtualRouterId }}
    priority @PRIORITY@
    advert_int {{ $ka.advertInt }}
    # Not nopreempt: a recovered preferred node takes the address back.
    garp_master_refresh {{ $ka.garpMasterRefresh }}
    # No authentication block: VRRP PASS auth is cleartext and was dropped
    # from VRRPv3.
    virtual_ipaddress {
        {{ tpl (toString $ka.vip) $root }}/32 dev @IFACE@
    }
{{- if or $ka.track $ka.extraTracks }}
    track_script {
{{- with $ka.track }}
        {{ .name | default "track" }}
{{- end }}
{{- range $ka.extraTracks }}
        {{ .name }}
{{- end }}
    }
{{- end }}
{{- if $ka.drain }}
    track_file {
        drain
    }
{{- end }}
}
{{- end }}

{{- /* Per-node render, run as the init container in the keepalived image. */ -}}
{{- define "common.keepalived.render" -}}
#!/bin/sh
# Render keepalived.conf for THIS node, then refuse to start on a bad config.
#   @IFACE@     the NIC carrying status.hostIP (NIC names differ per node)
#   @PRIORITY@  PRIORITY_PREFERRED on PREFERRED_NODE_IP, else PRIORITY_OTHER
set -eu

: "${NODE_IP:?NODE_IP is required (status.hostIP)}"
: "${PRIORITY_PREFERRED:?PRIORITY_PREFERRED is required}"
: "${PRIORITY_OTHER:?PRIORITY_OTHER is required}"
PREFERRED_NODE_IP="${PREFERRED_NODE_IP:-}"
src="${TEMPLATE:-/template/keepalived.conf}"
dst="${CONFIG:-/etc/keepalived/keepalived.conf}"

# Exact match on the address, so 192.168.2.1 never matches 192.168.2.12.
iface="$(ip -o -4 addr show | awk -v ip="$NODE_IP" '{split($4, a, "/"); if (a[1] == ip) {print $2; exit}}')"
if [ -z "$iface" ]; then
  echo "keepalived-render: no interface carries $NODE_IP" >&2
  exit 1
fi

prio="$PRIORITY_OTHER"
[ -n "$PREFERRED_NODE_IP" ] && [ "$NODE_IP" = "$PREFERRED_NODE_IP" ] && prio="$PRIORITY_PREFERRED"

sed -e "s/@IFACE@/$iface/g" -e "s/@PRIORITY@/$prio/g" "$src" > "$dst"
if grep -qE '@[A-Za-z0-9_]+@' "$dst"; then
  echo "keepalived-render: unrendered placeholder left in $dst" >&2
  exit 1
fi

echo "keepalived-render: node $NODE_IP iface $iface priority $prio"
# --config-test exits 0 for a missing file; only trust it on the path just written.
# It only warns when it drops a check ("... not found, ignoring", a track_file
# on a read-only mount), and the instance would run without it.
out="$(keepalived --config-test -l -G -f "$dst" 2>&1)" || { echo "$out" >&2; exit 1; }
[ -n "$out" ] && echo "$out"
if echo "$out" | grep -qiE 'ignoring|cannot be monitored'; then
  echo "keepalived-render: keepalived would drop part of $dst (see above)" >&2
  exit 1
fi
{{- end }}
