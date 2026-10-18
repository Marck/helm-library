#!/bin/sh
# `nodeSelector: {}` on a component must CLEAR the chart-level pin, not inherit it.
#
# common.daemonset got this right with hasKey. The other four gated on
# truthiness (`default $root.Values.nodeSelector $config.nodeSelector`, or
# `if or $config.nodeSelector $root.Values.nodeSelector`), and an empty map is
# falsy in Helm, so a component that explicitly asked to run anywhere silently
# kept the chart default. Verified 2026-10-16: `nodeSelector: {}` left all four
# adguard CronJobs pinned to the worker, which is exactly what the value was
# written to undo.
#
# Three cases per workload kind, because the fix has to keep two behaviours it
# did not break: an absent key still inherits, and an own selector still wins.
# Rendered against a real chart-level nodeSelector, or "inherits" proves nothing.
set -eu

DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
CHART="$DIR/common-test-chart"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

"$DIR/vendor-common.sh" "$CHART"
helm template test "$CHART" -f "$CHART/values.yaml" --set nodeSelector.tier=chart > "$WORK/render.yaml"

if python3 -c 'import yaml' 2>/dev/null; then PYRUN() { python3 "$@"; }
else PYRUN() { uv run --quiet --with pyyaml python3 "$@"; }; fi

PYRUN - "$WORK/render.yaml" <<'PY'
import sys, yaml

CHART_LEVEL = {"tier": "chart"}
OWN = {"node-role.kubernetes.io/control-plane": "true"}

docs = {}
for d in yaml.safe_load_all(open(sys.argv[1])):
    if isinstance(d, dict) and d.get("kind"):
        docs[d["metadata"]["name"]] = d

fails = []
def check(ok, msg):
    print(("ok   " if ok else "FAIL ") + msg)
    if not ok: fails.append(msg)

def podspec(name):
    d = docs.get(f"common-test-chart-test-{name}")
    if d is None:
        return None
    spec = d["spec"]
    if d["kind"] == "CronJob":
        spec = spec["jobTemplate"]["spec"]
    return spec["template"]["spec"]

for kind in ("deploy", "sts", "cron", "job", "ds"):
    clear, inherit, own = (podspec(f"ns-{c}-{kind}") for c in ("clear", "inherit", "own"))
    if None in (clear, inherit, own):
        check(False, f"{kind}: all three fixtures render")
        continue
    # The key must be ABSENT, not present and empty: `nodeSelector: {}` in a pod
    # spec is accepted by the API but it is not what "unpinned" should serialise to.
    check("nodeSelector" not in clear,
          f"{kind}: nodeSelector {{}} clears the chart-level pin (got {clear.get('nodeSelector')!r})")
    check(inherit.get("nodeSelector") == CHART_LEVEL,
          f"{kind}: an absent key still inherits the chart-level pin")
    check(own.get("nodeSelector") == OWN,
          f"{kind}: an own selector still wins over the chart-level pin")

if fails:
    sys.exit(f"FAIL: {len(fails)} nodeSelector assertion(s)")
print("PASS: nodeSelector {} clears, absent inherits, own wins")
PY
