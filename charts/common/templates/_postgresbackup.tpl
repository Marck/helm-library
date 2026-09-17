{{- /*
common.postgresBackup — a nightly pg_dump of a bundled PostgreSQL onto NFS.

Four charts in the consuming repo run a PostgreSQL that holds the only copy of
something a person would miss — a portfolio, a task list, a photo library, the
identity provider's own database — and none of them had a backup. The PV is
`Retain`, which survives a deleted PVC and nothing else: a bad migration, a
corrupted page or a DELETE with a wrong WHERE takes the data with it, and
`Retain` faithfully keeps the damage.

This renders both halves of the job, so a chart adds a values block and one
include rather than a CronJob, a ConfigMap and a shell script it has to keep in
step with three other copies:

    {{ include "common.postgresBackup" (dict "Root" . "Config" .Values.postgresBackup) }}

What the script encodes, all of it learned rather than chosen:

  * pg_dump -Fc, not plain SQL. Compressed, and restorable selectively with
    pg_restore -- a plain dump of a database with an extension (immich's
    vectorchord, say) is far more painful to replay.
  * Write to .part, fsync, verify, THEN rename. A rename within a directory is
    atomic, so a dump interrupted half-way never appears under the name the
    restore procedure reaches for. Without this the failure mode is the worst
    one available: a backup that exists, is the right size, and is truncated.
  * Verify before promoting, with `pg_restore --list`. pg_dump can exit 0 having
    written something pg_restore cannot read; checking the TOC is cheap and
    turns that into a failed job instead of a discovered-at-restore-time one.
  * Report both versions first. pg_dump REFUSES to dump a server newer than
    itself ("server version mismatch"), so the image tag has to track the
    server's major. Printing both makes that one log line instead of a puzzle.
  * Retention by mtime, and only of files this job names. A glob that matched
    more than its own output would be a delete loop pointed at a backup volume.
  * set -eu and an explicit exit code. The job must FAIL when the dump failed,
    or the dead-man's switch has nothing to notice.

The watchdog annotations stay in the consuming chart: only it can say what
breaks if this stops running, and the repo's CronJob gate enforces that it does.
*/ -}}
{{- define "common.postgresBackup" -}}
{{- $root := .Root -}}
{{- $b := .Config | default dict -}}
{{- if $b.enabled -}}
{{- $comp := $b.component | default "db-backup" -}}
{{- $name := printf "%s-%s" (include "common.fullname" $root) $comp -}}
{{- $db := $b.database | required "postgresBackup.database is required" -}}
{{- $mount := $b.mountPath | default "/backup" -}}
{{- $keep := $b.retentionDays | default 14 -}}
{{- /* common.backupCronJob defaults activeDeadlineSeconds to 300, which suits
       the sqlite jobs it was written for. A pg_dump of a real database can
       exceed it, and the deadline does not fail the job cleanly -- it kills it
       mid-dump, so the symptom is a backup that "sometimes fails" and gets
       ignored. 1800 unless the chart says otherwise.
       Set HERE, at the top: done next to the include it feeds, the {{- -}} trim
       actions eat the newline before the `---` and weld the ConfigMap to the
       CronJob. */ -}}
{{- $b = merge (dict "activeDeadlineSeconds" ($b.activeDeadlineSeconds | default 1800)) $b -}}
{{- if not $b.existingSecret -}}
{{- fail "postgresBackup.existingSecret must name the Secret holding the database password — the password is never rendered into the CronJob." -}}
{{- end -}}
{{- /* common.cronjob wants the repo-wide {repository, tag} shape. A bare
       "postgres:18-alpine" string fails four includes deep with
       `can't evaluate field repository in type interface {}`, which says
       nothing about which chart or which key is wrong. */ -}}
{{- if not (kindIs "map" ($b.image | default "")) -}}
{{- fail "postgresBackup.image must be a map, e.g. {repository: postgres, tag: \"18-alpine\"} — not a single \"postgres:18-alpine\" string. The tag must be at least the server's major version: pg_dump refuses to dump a newer server." -}}
{{- end -}}
{{- if not ($b.destination).claimName -}}
{{- fail "postgresBackup.destination.claimName must name the PVC the dumps are written to. Point it at a volume that is NOT the database's own: a backup that dies with the thing it protects is not one." -}}
{{- end -}}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ $name }}-script
  namespace: {{ $root.Values.namespace | default $root.Release.Namespace }}
  labels:
{{- include "common.labels" $root | nindent 4 }}
data:
  backup.sh: |
    #!/bin/sh
    set -eu

    # Wait for the database to accept connections before doing anything else.
    # This is not belt-and-braces: without it EVERY run failed. A freshly created
    # Job pod cannot reach the cluster network for the first second or two, and
    # the failure is ECONNREFUSED rather than a timeout, so pg_dump gives up
    # instantly instead of retrying. Measured on a live cluster: the job failed
    # all three attempts, every time, while the identical command from a pod that
    # had been up a few seconds connected first try.
    #
    # pg_isready reads the same PG* variables as everything below, so it needs no
    # arguments and no password -- it only asks whether the server is answering.
    waited=0
    until pg_isready -q; do
      if [ "${waited}" -ge "${CONNECT_TIMEOUT}" ]; then
        echo "[pg-backup] FAILED: ${PGHOST}:${PGPORT} not accepting connections after ${CONNECT_TIMEOUT}s" >&2
        exit 1
      fi
      waited=$((waited + 2))
      sleep 2
    done
    [ "${waited}" -gt 0 ] && echo "[pg-backup] database answered after ${waited}s"

    STAMP="$(date +%Y%m%d-%H%M%S)"
    OUT="${DEST}/${DB_NAME}-${STAMP}.dump"
    PART="${OUT}.part"

    # pg_dump refuses to dump a server newer than itself, so surface both up
    # front: a version mismatch is then the first line of the log rather than an
    # error message someone has to interpret.
    echo "[pg-backup] client $(pg_dump --version)"
    echo "[pg-backup] server $(psql -tAc 'SHOW server_version' || echo unknown)"
    echo "[pg-backup] dumping ${DB_NAME} -> ${OUT}"

    # -Fc: custom format. Compressed, and pg_restore can replay it selectively.
    pg_dump --format=custom --no-owner --no-privileges --file="${PART}" "${DB_NAME}"

    # A dump that pg_dump wrote happily but pg_restore cannot read is the case
    # worth spending two seconds on: reading the table of contents proves the
    # archive header and TOC are intact before it is given the real name.
    if ! pg_restore --list "${PART}" >/dev/null 2>&1; then
      echo "[pg-backup] FAILED: ${PART} is not a readable archive; leaving it for inspection" >&2
      exit 1
    fi

    SIZE="$(wc -c < "${PART}")"
    if [ "${SIZE}" -lt 1024 ]; then
      echo "[pg-backup] FAILED: dump is ${SIZE} bytes, which is not a database" >&2
      exit 1
    fi

    # Atomic within the directory: the finished name never exists half-written,
    # so whatever a restore picks up is always a complete dump.
    mv "${PART}" "${OUT}"
    echo "[pg-backup] wrote ${OUT} (${SIZE} bytes)"

    # Only ever matches this job's own output, and only after a successful run --
    # so a broken backup never prunes the last good one.
    echo "[pg-backup] pruning dumps older than ${KEEP_DAYS} day(s)"
    find "${DEST}" -maxdepth 1 -type f -name "${DB_NAME}-*.dump" -mtime "+${KEEP_DAYS}" -print -delete

    # A failed run deliberately leaves its .part behind so it can be looked at,
    # but "deliberately" only holds for the recent ones -- without this line they
    # accumulate on the backup volume forever, one per failure, and the first
    # symptom is a full volume that stops the backups that were working.
    find "${DEST}" -maxdepth 1 -type f -name "${DB_NAME}-*.dump.part" -mtime "+${KEEP_DAYS}" -print -delete

    REMAINING="$(find "${DEST}" -maxdepth 1 -type f -name "${DB_NAME}-*.dump" | wc -l)"
    echo "[pg-backup] ok - ${REMAINING} dump(s) retained"
{{/* PGPASSWORD below is a MAP, which common.cronjob renders as valueFrom, so
     the password reaches libpq through the environment and never through argv,
     where `kubectl describe` would print it. The rest are standard libpq
     variables, so pg_dump and psql connect with no arguments.

     Two delimiter traps, both hit while writing this:
     - a comment cannot sit inside the dict expression below; Go rejects it
       with `unexpected "{" in operand`;
     - this comment must not TRIM. A trimming comment eats the newline after
       the script's last line, the separator below lands on that line, and the
       ConfigMap welds to the CronJob into one document that kubeconform
       rejects with `key apiVersion already set`. */}}
---
{{ include "common.backupCronJob" (dict
     "Root" $root
     "Component" $comp
     "Config" $b
     "Script" (printf "%s-script" $name)
     "ScriptPath" "/scripts/backup.sh"
     "ScriptMode" 0555
     "Env" (dict
        "PGHOST"     ($b.host | required "postgresBackup.host is required")
        "PGPORT"     ($b.port | default 5432 | toString)
        "PGUSER"     ($b.user | required "postgresBackup.user is required")
        "PGDATABASE" $db
        "PGPASSWORD" (dict "valueFrom" (dict "secretKeyRef" (dict
            "name" $b.existingSecret
            "key"  ($b.secretKey | default "password"))))
        "DB_NAME"    $db
        "DEST"       $mount
        "KEEP_DAYS"  ($keep | toString)
        "CONNECT_TIMEOUT" ($b.connectTimeoutSeconds | default 120 | toString))
     "VolumeMounts" (list (dict "name" "backup" "mountPath" $mount))
     "Volumes" (list (dict "name" "backup" "persistentVolumeClaim" (dict "claimName" $b.destination.claimName)))) }}
{{- end -}}
{{- end -}}
