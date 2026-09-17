#!/bin/sh
# common.postgresBackup renders a CronJob and the script it runs. A passing
# render proves almost none of what matters about a backup, so these assert the
# properties that decide whether it is worth having:
#
#   * the password reaches the job as a secretKeyRef, never as a literal -- a
#     backup job that carries a plaintext password in its pod spec hands it to
#     anyone who can read a CronJob;
#   * the watchdog annotations survive the two includes between the chart and
#     the rendered CronJob. They are the only reason anyone finds out the backup
#     stopped, and the repo's CronJob gate checks the chart, not the render;
#   * activeDeadlineSeconds is NOT the generic 300s default -- that suits the
#     sqlite jobs backupCronJob was written for and kills a real pg_dump
#     mid-flight, which presents as a backup that "sometimes fails";
#   * the script writes to .part and renames, because the failure that matters
#     is a truncated dump sitting under the name a restore reaches for;
#   * it verifies with pg_restore --list before promoting, since pg_dump can
#     exit 0 having written an archive pg_restore cannot read;
#   * an image given as a bare string fails HERE with a message naming the key,
#     rather than four includes deep with "can't evaluate field repository".
set -eu

DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
CHART="$DIR/common-test-chart"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

"$DIR/vendor-common.sh" >/dev/null

helm template test "$CHART" > "$WORK/out.yaml"

fail() { echo "FAIL: $1" >&2; exit 1; }

# --- the CronJob -------------------------------------------------------------
grep -q 'name: common-test-chart-test-db-backup$' "$WORK/out.yaml" \
  || fail "no db-backup CronJob rendered"

grep -q 'jobwatchdog.mastcloud.nl/enabled' "$WORK/out.yaml" \
  || fail "watchdog annotations were dropped between the chart and the CronJob"

grep -q 'activeDeadlineSeconds: 1800' "$WORK/out.yaml" \
  || fail "activeDeadlineSeconds is not 1800 -- a pg_dump would be killed at the generic 300s default"

grep -q 'secretKeyRef' "$WORK/out.yaml" \
  || fail "PGPASSWORD is not a secretKeyRef"

grep -qE 'PGPASSWORD.*value: ' "$WORK/out.yaml" \
  && fail "PGPASSWORD rendered as a literal value" || true

grep -q 'automountServiceAccountToken: false' "$WORK/out.yaml" \
  || fail "the backup job still mounts a ServiceAccount token"

# --- the script --------------------------------------------------------------
grep -q '\.part' "$WORK/out.yaml" \
  || fail "script does not stage through a .part file, so a torn dump can take the final name"

grep -q 'pg_restore --list' "$WORK/out.yaml" \
  || fail "script does not verify the archive before promoting it"

grep -q 'format=custom' "$WORK/out.yaml" \
  || fail "script does not use the custom (restorable, compressed) format"

grep -q 'dump.part" -mtime' "$WORK/out.yaml" \
  || fail "script never prunes .part files, so failed runs accumulate forever"

# --- the guard rails ---------------------------------------------------------
if helm template test "$CHART" --set 'postgresBackup.image=postgres:18-alpine' >/dev/null 2>&1; then
  fail "a bare image string was accepted; it must fail with a message naming the key"
fi

if helm template test "$CHART" --set 'postgresBackup.destination.claimName=null' >/dev/null 2>&1; then
  fail "a missing destination.claimName was accepted; dumps would have nowhere to go"
fi

echo "postgres-backup: ok"
