{{- /*
common.ensureOwnership — hand a mounted directory to the uid the workload runs as.

Why this exists
---------------
An NFS export created on a NAS arrives owned by root. A workload that runs
unprivileged — as it should — then cannot create a single file in its own
directory, and the failure is quiet: the Deployment is Available, the CronJob
keeps its schedule, and only the app's own log says "permission denied". A key
backup in the consuming repo failed this way on every run for two days before
anything noticed, which is the whole reason this exists.

Only chown/chmod need root, and only once. So this renders exactly that: a tiny
init container, root, CHOWN+FOWNER and nothing else, which hands the directory
over and exits. The workload itself keeps running as its own uid.

Idempotent: a no-op once the ownership is right, and it repairs the directory
again if the share is ever recreated on the NAS.

Usage — a values block on the workload's Config (or chart root):

    ensureOwnership:
      enabled: true
      # uid/gid default to the pod's runAsUser / runAsGroup (or fsGroup).
      paths:
        - volume: config          # a volume the pod already declares
          mountPath: /config      # where this container should mount it
          # mode: "0700"          # optional; omitted leaves the mode alone
          # recursive: true       # optional; see the warning below

NEVER point this at a directory more than one chart writes to. chown is not a
merge: pointing it at a shared media tree hands that tree to one app's uid and
takes it away from every other app that mounts it. One chart, one directory.

`recursive` walks the whole tree on EVERY pod start. It is for a directory whose
contents also arrived root-owned; on a large tree it is slow and it rewrites
ownership the apps may be relying on. Default off, and leave it off unless a
specific restore made it necessary.
*/ -}}
{{- define "common.ensureOwnership" -}}
{{- $root := .Root -}}
{{- $config := .Config | default dict -}}
{{- $eo := .EnsureOwnership | default dict -}}
{{- $psc := (default $root.Values.podSecurityContext $config.podSecurityContext) | default dict -}}
{{- /* Charts put the uid in either place: some in the pod securityContext, some
       only on the container (a pod context carrying just an fsGroup is common
       here). Look in both before asking for it explicitly. */ -}}
{{- $csc := (default $root.Values.securityContext $config.securityContext) | default dict -}}
{{- $uid := $eo.uid | default $psc.runAsUser | default $csc.runAsUser -}}
{{- $gid := $eo.gid | default $psc.runAsGroup | default $csc.runAsGroup | default $psc.fsGroup | default $uid -}}
{{- if kindIs "invalid" $uid -}}
{{- fail "ensureOwnership: no uid — set ensureOwnership.uid, or a podSecurityContext.runAsUser for it to inherit" -}}
{{- end -}}
{{- $paths := $eo.paths | default list -}}
{{- if not $paths -}}
{{- fail "ensureOwnership: paths is empty — name the directories this workload owns (never a share another chart writes to)" -}}
{{- end -}}
{{- $steps := list -}}
{{- range $p := $paths -}}
{{- $mp := $p.mountPath | required "ensureOwnership: each path needs a mountPath" -}}
{{- $u := $p.uid | default $uid -}}
{{- $g := $p.gid | default $gid -}}
{{- $flag := ternary "-R " "" ($p.recursive | default false) -}}
{{- $steps = append $steps (printf "chown %s%d:%d %s" $flag (int $u) (int $g) $mp) -}}
{{- if $p.mode -}}
{{- $steps = append $steps (printf "chmod %s %s" $p.mode $mp) -}}
{{- end -}}
{{- end -}}
{{- $named := list -}}
{{- range $p := $paths -}}{{- $named = append $named $p.mountPath -}}{{- end -}}
{{- $steps = append $steps (printf "echo \"ensure-ownership: %s handed to %d:%d\"" (join ", " $named) (int $uid) (int $gid)) -}}
- name: {{ $eo.name | default "ensure-ownership" }}
  image: {{ $eo.image | default "busybox:1.37" | quote }}
  imagePullPolicy: {{ $eo.pullPolicy | default "IfNotPresent" }}
  command:
    - sh
    - -c
    - {{ join " && " $steps | quote }}
  securityContext:
    # root, because chown is the one thing that needs it -- and nothing else is
    # granted: no privilege escalation, a read-only root filesystem, every
    # capability dropped except the two a chown/chmod actually uses.
    runAsUser: 0
    runAsGroup: 0
    runAsNonRoot: false
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    capabilities:
      drop:
        - ALL
      add:
        - CHOWN
        - FOWNER
  resources:
    {{- toYaml ($eo.resources | default (dict "requests" (dict "cpu" "10m" "memory" "32Mi") "limits" (dict "memory" "64Mi"))) | nindent 4 }}
  volumeMounts:
    {{- range $p := $paths }}
    - name: {{ $p.volume | required "ensureOwnership: each path needs a volume name" }}
      mountPath: {{ $p.mountPath }}
      {{- with $p.subPath }}
      subPath: {{ . }}
      {{- end }}
    {{- end }}
{{- end -}}

{{- /* Every init container a workload runs, in the order the dependencies
       demand:

         1. ensureOwnership -- anything later may need to WRITE to the directory,
            so it has to be writable first;
         2. waitFor -- a dependency that is not up yet; nothing after this can
            work without it, and failing here names what was missing;
         3. the chart's own initContainers, which may rely on all of the above --
            seeding a config file, restoring a database, editing a settings file.

       A chart that needs a step of its own puts it in `initContainers`; nothing
       application-specific belongs in this library.

       Each block is independent: a chart that declares none of them renders no
       initContainers key at all, exactly as before. */ -}}
{{- define "common.initContainers" -}}
{{- $root := .Root -}}
{{- $config := .Config | default dict -}}
{{- /* Read from the workload's own Config and nowhere else. For a chart's main
       workload that Config IS the root values (common.deployment/statefulset
       default to them), so a values-level block applies to it. A second
       component -- a node agent, a bundled database -- passes its own Config and
       declares its own volumes; inheriting the main workload's paths would mount
       a volume it never declared and the pod would be rejected. So inheritance
       stops here, deliberately. */ -}}
{{- $chunks := list -}}
{{- $eo := $config.ensureOwnership | default dict -}}
{{- if $eo.enabled -}}
{{- $chunks = append $chunks (include "common.ensureOwnership" (dict "Root" $root "Config" $config "EnsureOwnership" $eo)) -}}
{{- end -}}
{{- $w := $config.waitFor | default dict -}}
{{- if $w.targets -}}
{{- $chunks = append $chunks (include "common.waitFor" (dict "Root" $root "Config" $config "WaitFor" $w)) -}}
{{- end -}}
{{- with $config.initContainers -}}
{{- $chunks = append $chunks (toYaml .) -}}
{{- end -}}
{{- /* Joined with a newline rather than concatenated: each block is a YAML list
       whose last line has no trailing newline of its own, and running two of
       them together silently welds the next `- name:` onto the previous line. */ -}}
{{- $clean := list -}}
{{- range $c := $chunks -}}
{{- $clean = append $clean (trim $c) -}}
{{- end -}}
{{ join "\n" $clean }}
{{- end -}}
