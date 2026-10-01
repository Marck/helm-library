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
{{- $conf := include "common.keepalived.conf" (dict "Root" $root "Config" $ka) }}
{{- $render := include "common.keepalived.render" . }}
{{ include "common.configmap" (dict "Root" $root "Name" $name "Data" (dict
      "keepalived.conf" $conf
      "keepalived-render.sh" $render)) }}
---
{{- $nodeIP := dict "valueFrom" (dict "fieldRef" (dict "fieldPath" "status.hostIP")) }}
{{- $env := dict }}
{{- with $ka.track }}
{{- $_ := set $env "TRACK_TARGET" $nodeIP }}
{{- range $k, $v := (.env | default dict) }}
{{- $_ := set $env $k (tpl (toString $v) $root) }}
{{- end }}
{{- end }}
{{- $_ := set $ka "env" $env }}
{{- $image := printf "%s:%s" $ka.image.repository (toString $ka.image.tag) }}
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
      "volumeMounts" (list
        (dict "name" "template" "mountPath" "/template" "readOnly" true)
        (dict "name" "config" "mountPath" "/etc/keepalived")))) }}
{{- $_ := set $ka "volumeMounts" (list
      (dict "name" "config" "mountPath" "/etc/keepalived" "readOnly" true)
      (dict "name" "run" "mountPath" "/run")) }}
{{- $_ := set $ka "volumes" (list
      (dict "name" "template" "configMap" (dict "name" $name))
      (dict "name" "config" "emptyDir" (dict "medium" "Memory" "sizeLimit" "1Mi"))
      (dict "name" "run" "emptyDir" (dict "medium" "Memory" "sizeLimit" "1Mi"))) }}
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
{{- if $ka.track }}
    track_script {
        {{ $ka.track.name | default "track" }}
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
keepalived --config-test -l -G -f "$dst"
{{- end }}
