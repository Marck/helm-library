{{- /*
common.waitFor — hold the pod at Init until a dependency answers on its port.

Why this exists
---------------
An app that starts before its database does not fail cleanly: it crashes, gets
restarted, and ArgoCD shows Degraded on the app rather than on the thing that is
actually late. Gating the app on a reachable dependency turns that into a pod
sitting in Init with a log line naming what it is waiting for.

Two charts here grew their own version of this loop, and they disagreed on the
part that matters. One was bounded (300s, then a loud failure); the other used
`until nc -z ...` with no bound at all, so a database that never came up left the
pod in Init forever with nothing to read — and it pulled `busybox:latest`, which
is a different image on every node and every day.

So: always bounded, always a pinned image, and the failure says which dependency
never answered.

    waitFor:
      timeoutSeconds: 300      # per target; default 300
      intervalSeconds: 5       # default 5
      image: busybox:1.38      # pin it; no default tag chasing
      targets:
        - host: myapp-mariadb
          port: 3306

It renders ONE init container that checks each target in order, so a pod waiting
on two dependencies still costs one container. It runs as the workload's own uid
with every capability dropped -- opening a TCP connection needs nothing.
*/ -}}
{{- define "common.waitFor" -}}
{{- $root := .Root -}}
{{- $config := .Config | default dict -}}
{{- $w := .WaitFor | default dict -}}
{{- $targets := $w.targets | default list -}}
{{- if not $targets -}}
{{- fail "waitFor: targets is empty — name the host/port to wait for, or drop the block" -}}
{{- end -}}
{{- $timeout := int ($w.timeoutSeconds | default 300) -}}
{{- $interval := int ($w.intervalSeconds | default 5) -}}
{{- if lt $timeout $interval -}}
{{- fail (printf "waitFor: timeoutSeconds (%d) is shorter than intervalSeconds (%d) — the check would never run twice" $timeout $interval) -}}
{{- end -}}
{{- $psc := (default $root.Values.podSecurityContext $config.podSecurityContext) | default dict -}}
{{- $csc := (default $root.Values.securityContext $config.securityContext) | default dict -}}
{{- $uid := $w.uid | default $psc.runAsUser | default $csc.runAsUser -}}
{{- $calls := list -}}
{{- range $t := $targets -}}
{{- $host := $t.host | required "waitFor: each target needs a host" -}}
{{- $port := $t.port | required "waitFor: each target needs a port" -}}
{{- $calls = append $calls (printf "wait_for %s %d %d %d" $host (int $port) (int ($t.timeoutSeconds | default $timeout)) (int ($t.intervalSeconds | default $interval))) -}}
{{- end -}}
- name: {{ $w.name | default "wait-for-deps" }}
  image: {{ $w.image | default "busybox:1.38" | quote }}
  imagePullPolicy: {{ $w.pullPolicy | default "IfNotPresent" }}
  command:
    - sh
    - -c
    - |
      set -eu
      # Bounded on purpose: a dependency that never comes up must fail this
      # container with a message, not leave the pod in Init forever.
      wait_for() {
        host=$1; port=$2; limit=$3; step=$4
        waited=0
        while [ "$waited" -lt "$limit" ]; do
          # busybox `nc -z`: no bash here, so no /dev/tcp.
          if nc -z -w 3 "$host" "$port"; then
            echo "$host:$port is accepting connections"
            return 0
          fi
          waited=$((waited + step))
          sleep "$step"
        done
        echo "$host:$port unreachable after ${limit}s" >&2
        exit 1
      }
      {{- range $c := $calls }}
      {{ $c }}
      {{- end }}
  securityContext:
    # Opening a TCP connection needs no privileges at all.
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    capabilities:
      drop:
        - ALL
    {{- if not (kindIs "invalid" $uid) }}
    runAsUser: {{ int $uid }}
    runAsNonRoot: {{ ne (int $uid) 0 }}
    {{- end }}
  resources:
    {{- toYaml ($w.resources | default (dict "requests" (dict "cpu" "10m" "memory" "32Mi") "limits" (dict "memory" "64Mi"))) | nindent 4 }}
{{- end -}}
