#!/bin/sh
# Helm's `default` treats 0 as empty, so `$config.backoffLimit | default 3`
# silently ignores an explicit `backoffLimit: 0`. The consequence is not
# cosmetic: a Job that asked never to retry runs its side effects three more
# times on failure, and `failedJobsHistoryLimit: 0` keeps Jobs that were meant
# to be discarded. These assert that an explicit 0 survives, and that a field
# left unset still gets the documented default.
set -eu

DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
CHART="$DIR/common-test-chart"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

"$DIR/vendor-common.sh" "$CHART"
helm template test "$CHART" -f "$CHART/values.yaml" > "$WORK/render.yaml"

if python3 -c 'import yaml' 2>/dev/null; then PYRUN="python3"; else PYRUN="uv run --with pyyaml python3"; fi

fails=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }

# Read a spec field off a named document. On a CronJob the Job settings live
# under .spec.jobTemplate.spec, so the path is given per assertion.
assert_field() {
  name="$1"; path="$2"; want="$3"; label="$4"
  got="$($PYRUN - "$WORK/render.yaml" "$name" "$path" <<'PY'
import sys, yaml
render, name, path = sys.argv[1], sys.argv[2], sys.argv[3]
for d in yaml.safe_load_all(open(render)):
    if not d or (d.get("metadata") or {}).get("name") != name:
        continue
    node = d
    for key in path.split("."):
        node = node[key]
    print(repr(node))
    break
else:
    print("<no such document>")
PY
)"
  if [ "$got" = "$want" ]; then ok "$label"; else bad "$label (got ${got}, want ${want})"; fi
}

assert_field common-test-chart-test-zero-int-job spec.backoffLimit 0 \
  "job keeps an explicit backoffLimit: 0"
assert_field common-test-chart-test-zero-int-cron spec.jobTemplate.spec.backoffLimit 0 \
  "cronjob keeps an explicit backoffLimit: 0"
assert_field common-test-chart-test-zero-int-cron spec.successfulJobsHistoryLimit 0 \
  "cronjob keeps successfulJobsHistoryLimit: 0"
assert_field common-test-chart-test-zero-int-cron spec.failedJobsHistoryLimit 0 \
  "cronjob keeps failedJobsHistoryLimit: 0"

# An unset field must still land on its documented default, not on empty.
assert_field common-test-chart-test-scoped-hook-job spec.backoffLimit 3 \
  "job that sets nothing still defaults to backoffLimit 3"
assert_field common-test-chart-test-ttl-cron spec.successfulJobsHistoryLimit 3 \
  "cronjob that sets nothing still defaults to successfulJobsHistoryLimit 3"

[ "$fails" -eq 0 ] || { echo "FAIL: $fails zero-value assertion(s)"; exit 1; }
echo "PASS: explicit zero on integer fields"
