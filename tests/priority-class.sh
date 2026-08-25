#!/bin/sh
# priorityClassName decides whether a pod survives node pressure. It matters for
# workloads whose failure is invisible at the failure site: evict a per-node DNS
# cache and what you see is applications timing out, not a pod being evicted.
#
# A passing render is weak evidence here, so these assert the three properties
# that actually decide whether the field works:
#
#   * it lands at pod-spec level in BOTH nesting depths — a DaemonSet's
#     .spec.template.spec and a CronJob's .spec.jobTemplate.spec.template.spec.
#     An indentation slip puts it under the wrong key, where the API server
#     rejects it (or, worse, a schema-less path ignores it);
#   * a workload that does not ask for one stays byte-identical to before, so
#     this is an opt-in and not a change to every chart in the repo;
#   * the chart-wide default (root values) applies to a component that sets
#     nothing, and a component value overrides it.
set -eu

DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
CHART="$DIR/common-test-chart"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

helm dependency update "$CHART" >/dev/null 2>&1
helm template test "$CHART" -f "$CHART/values.yaml" > "$WORK/render.yaml"
helm template test "$CHART" -f "$CHART/values.yaml" \
  --set priorityClassName=chart-wide-default > "$WORK/default.yaml"

# pyyaml is not in the stdlib; fall back to uv the way the other tests do.
if python3 -c 'import yaml' 2>/dev/null; then PYRUN="python3"; else PYRUN="uv run --with pyyaml python3"; fi

fails=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }

# Assert the field sits at pod-spec level of a named workload, by parsing the
# document rather than grepping — grep cannot tell a pod spec from a job spec.
assert_at_podspec() {
  render="$1"; name="$2"; want="$3"; label="$4"
  got="$($PYRUN - "$render" "$name" <<'PY'
import sys, yaml
path, name = sys.argv[1], sys.argv[2]
for d in yaml.safe_load_all(open(path)):
    if not d or (d.get("metadata") or {}).get("name") != name:
        continue
    spec = d["spec"]
    if d["kind"] == "CronJob":
        spec = spec["jobTemplate"]["spec"]
    print((spec["template"]["spec"].get("priorityClassName") or ""))
    break
else:
    print("<no such document>")
PY
)"
  if [ "$got" = "$want" ]; then ok "$label"; else bad "$label (got '${got}', want '${want}')"; fi
}

assert_at_podspec "$WORK/render.yaml" common-test-chart-test-priority-agent \
  system-node-critical "daemonset carries priorityClassName at pod-spec level"
assert_at_podspec "$WORK/render.yaml" common-test-chart-test-priority-cron \
  system-cluster-critical "cronjob carries priorityClassName at pod-spec level"

# Opt-in: a workload that asks for nothing must not grow the field.
assert_at_podspec "$WORK/render.yaml" common-test-chart-test-dns-fallback-app \
  "" "a workload that asks for nothing stays without priorityClassName"

# Chart-wide default applies where nothing was set...
assert_at_podspec "$WORK/default.yaml" common-test-chart-test-dns-fallback-app \
  chart-wide-default "root-level priorityClassName reaches a component that sets none"
# ...and a component value still wins over it.
assert_at_podspec "$WORK/default.yaml" common-test-chart-test-priority-agent \
  system-node-critical "component priorityClassName overrides the chart-wide default"

[ "$fails" -eq 0 ] || { echo "FAIL: $fails priorityClassName assertion(s)"; exit 1; }
echo "PASS: priorityClassName"
