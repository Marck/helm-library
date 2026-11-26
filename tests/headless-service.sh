#!/bin/sh
# A headless Service is only headless if `clusterIP: None` reaches the API
# server as that exact string, at spec level. Asserted by parsing the render:
#
#   * the headless fixture has clusterIP "None" and publishNotReadyAddresses
#     true, and keeps its UDP port;
#   * every other Service renders neither key, so this is opt-in and existing
#     Services (whose clusterIP is immutable) are not changed.
set -eu

DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
CHART="$DIR/common-test-chart"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

"$DIR/vendor-common.sh" "$CHART"
helm template test "$CHART" -f "$CHART/values.yaml" > "$WORK/render.yaml"

if python3 -c 'import yaml' 2>/dev/null; then PYRUN="python3"; else PYRUN="uv run --with pyyaml python3"; fi

$PYRUN - "$WORK/render.yaml" <<'PY'
import sys, yaml
svcs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d and d["kind"] == "Service"]
fails = 0
def check(cond, msg):
    global fails
    print(("ok   " if cond else "FAIL ") + msg)
    fails += not cond
head = [s for s in svcs if s["metadata"]["name"].endswith("-headless")]
check(len(head) == 1, "the headless fixture renders one Service")
if head:
    spec = head[0]["spec"]
    check(spec.get("clusterIP") == "None", "clusterIP is the string None at spec level")
    check(spec.get("publishNotReadyAddresses") is True, "publishNotReadyAddresses is true")
    check([(p["port"], p["protocol"]) for p in spec["ports"]] == [(5353, "UDP")], "the UDP port is kept")
others = [s for s in svcs if not s["metadata"]["name"].endswith("-headless")]
check(len(others) > 0, "other Services exist to compare against")
check(all("clusterIP" not in s["spec"] and "publishNotReadyAddresses" not in s["spec"] for s in others),
      "no other Service renders clusterIP or publishNotReadyAddresses")
sys.exit(1 if fails else 0)
PY
