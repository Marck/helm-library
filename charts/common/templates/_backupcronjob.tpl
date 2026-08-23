{{- /*
common.backupCronJob — the CronJob wrapper every backup job in helm-charts had
its own copy of.

Four charts in the consuming repo each wrote out the same ~30 lines to say the
same things: run this script from a ConfigMap, never concurrently, give up rather
than retry forever, keep one success and two failures, clean the finished Job up,
and give the script a writable /tmp. The values that actually differ between them
are the schedule, the script, and what it mounts.

The defaults encode decisions that were learned, not chosen:

  * ttlSecondsAfterFinished — without it a failed Job sits in the namespace until
    failedJobsHistoryLimit finally evicts it, and ArgoCD reports the app Degraded
    for the whole time (a DNS blip on 2026-08-16 left Error Jobs lying around two
    days later);
  * concurrencyPolicy Forbid — two copies of a backup writing the same file is
    how a good backup becomes a torn one;
  * restartPolicy Never + a bounded activeDeadlineSeconds — a backup that hangs
    must fail and alert, not retry silently;
  * automountServiceAccountToken false — these scripts talk to a disk, not to the
    API server. A backup that DOES need it — one that writes its result into a
    Secret, say — declares a serviceAccount, and then the token is left mounted:
    the default is off only where nothing asked for it.

Anything here can be overridden from the chart's own backup values block.

    {{ include "common.backupCronJob" (dict
         "Root" . "Component" "db-backup" "Config" .Values.dbBackup
         "Script" "myapp-db-backup-script"
         "Env" (dict "DB_PATH" "/data/db.db")
         "VolumeMounts" (list (dict "name" "data" "mountPath" "/data"))
         "Volumes" (list (dict "name" "data" "persistentVolumeClaim" (dict "claimName" "data-myapp-0")))) }}

The dead-man's-switch annotations stay in the chart: `jobwatchdog…/description`
has to say what THIS backup protects, and the repo's CronJob gate enforces that
every CronJob carries them.
*/ -}}
{{- define "common.backupCronJob" -}}
{{- $root := .Root -}}
{{- $comp := .Component | default "backup" -}}
{{- $b := .Config | default dict -}}
{{- $script := .Script | required "backupCronJob: Script must name the ConfigMap holding the script" -}}
{{- $path := .ScriptPath | default "/scripts/backup.sh" -}}
{{- /* HOME is set because a read-only root filesystem plus a script that shells
       out (sqlite3, tar, openssl) otherwise writes to a home that is not there. */ -}}
{{- $env := merge (dict "HOME" "/tmp") (.Env | default dict) -}}
{{- $mounts := concat
      (list
        (dict "name" "scripts" "mountPath" (dir $path) "readOnly" true))
      (.VolumeMounts | default list)
      (list (dict "name" "tmp" "mountPath" "/tmp")) -}}
{{- $scriptVolume := dict "name" "scripts" "configMap" (dict "name" $script) -}}
{{- if .ScriptMode -}}
{{- $_ := set (index $scriptVolume "configMap") "defaultMode" .ScriptMode -}}
{{- end -}}
{{- $volumes := concat
      (list $scriptVolume)
      (.Volumes | default list)
      (list (dict "name" "tmp" "emptyDir" (dict))) -}}
{{- $config := dict
    "annotations"                  ($b.annotations | default dict)
    "schedule"                     ($b.schedule | required "backupCronJob: the chart must set a schedule")
    "concurrencyPolicy"            ($b.concurrencyPolicy | default "Forbid")
    "successfulJobsHistoryLimit"   ($b.successfulJobsHistoryLimit | default 1)
    "failedJobsHistoryLimit"       ($b.failedJobsHistoryLimit | default 2)
    "backoffLimit"                 ($b.backoffLimit | default 2)
    "activeDeadlineSeconds"        ($b.activeDeadlineSeconds | default 300)
    "ttlSecondsAfterFinished"      ($b.ttlSecondsAfterFinished | default 300)
    "restartPolicy"                ($b.restartPolicy | default "Never")
    "image"                        $b.image
    "command"                      (list "/bin/sh" $path)
    "nodeSelector"                 $b.nodeSelector
    "podSecurityContext"           $b.podSecurityContext
    "securityContext"              $b.securityContext
    "ensureOwnership"              ($b.ensureOwnership | default dict)
    "env"                          $env
    "resources"                    $b.resources
    "volumeMounts"                 $mounts
    "volumes"                      $volumes -}}
{{- if $b.serviceAccount }}{{- $_ := set $config "serviceAccount" $b.serviceAccount }}{{- end }}
{{- /* Off unless this backup declares a serviceAccount -- forcing it off there
       would take the token away from a job that asked for one. */ -}}
{{- if hasKey $b "automountServiceAccountToken" -}}
{{- $_ := set $config "automountServiceAccountToken" $b.automountServiceAccountToken -}}
{{- else if not $b.serviceAccount -}}
{{- $_ := set $config "automountServiceAccountToken" false -}}
{{- end -}}
{{- /* Only pass `suspend` when the chart actually sets it, so the rendered
       CronJob does not carry an explicit null. */ -}}
{{- if hasKey $b "suspend" }}{{- $_ := set $config "suspend" $b.suspend }}{{- end }}
{{ include "common.cronjob" (dict "Root" $root "Component" $comp "Config" $config) }}
{{- end -}}
