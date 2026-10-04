#!/bin/sh
# affinity on the long-running helpers (deployment, statefulset, daemonset).
#
# Up to 0.19.0 the block was indented level with `affinity:` itself, so YAML
# read it as `affinity: null` followed by a stray pod-spec key such as
# `nodeAffinity`. The render succeeded and looked plausible; the affinity was
# simply never applied. No chart set it, which is why it went unnoticed until
# apps/gatus needed a preferred node affinity.
#
# What is asserted, by reading the parsed document rather than grepping:
#
#   * the affinity a component passes lands under pod-spec `affinity` with its
#     full structure, on all three helpers;
#   * no affinity key (nodeAffinity, podAffinity, podAntiAffinity) leaks onto
#     the pod spec itself;
#   * the chart-wide default (root values) reaches a workload that sets none;
#   * a workload that asks for nothing still renders no affinity at all.
set -eu

DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
CHART="$DIR/common-test-chart"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

"$DIR/vendor-common.sh" "$CHART"
helm template test "$CHART" -f "$CHART/values.yaml" > "$WORK/render.yaml"
helm template test "$CHART" -f "$CHART/values.yaml" \
  --set-json 'affinity={"podAntiAffinity":{"preferredDuringSchedulingIgnoredDuringExecution":[{"weight":1,"podAffinityTerm":{"topologyKey":"kubernetes.io/hostname"}}]}}' \
  > "$WORK/default.yaml"

if python3 -c 'import yaml' 2>/dev/null; then PYRUN="python3"; else PYRUN="uv run --with pyyaml python3"; fi

fails=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }

# Prints "<affinity as JSON>|<stray keys>" for the named workload's pod spec.
podspec_affinity() {
  $PYRUN - "$1" "$2" <<'PY'
import json, sys, yaml
path, name = sys.argv[1], sys.argv[2]
for d in yaml.safe_load_all(open(path)):
    if not d or d.get("kind") not in ("Deployment", "StatefulSet", "DaemonSet"):
        continue
    if (d.get("metadata") or {}).get("name") != name:
        continue
    spec = d["spec"]["template"]["spec"]
    stray = sorted(k for k in ("nodeAffinity", "podAffinity", "podAntiAffinity") if k in spec)
    print(json.dumps(spec.get("affinity"), sort_keys=True) + "|" + ",".join(stray))
    break
else:
    print("<no such document>|")
PY
}

want_node='{"nodeAffinity": {"preferredDuringSchedulingIgnoredDuringExecution": [{"preference": {"matchExpressions": [{"key": "node-role.kubernetes.io/worker", "operator": "In", "values": ["worker"]}]}, "weight": 100}]}}'
for comp in affinity-deploy affinity-sts affinity-ds; do
  got="$(podspec_affinity "$WORK/render.yaml" "common-test-chart-test-$comp")"
  if [ "$got" = "$want_node|" ]; then
    ok "$comp: affinity at pod-spec level, nothing stray"
  else
    bad "$comp: got '$got'"
  fi
done

got="$(podspec_affinity "$WORK/render.yaml" common-test-chart-test-app)"
if [ "$got" = "null|" ]; then ok "a workload that sets none renders no affinity"; else bad "default workload: got '$got'"; fi

want_anti='{"podAntiAffinity": {"preferredDuringSchedulingIgnoredDuringExecution": [{"podAffinityTerm": {"topologyKey": "kubernetes.io/hostname"}, "weight": 1}]}}'
got="$(podspec_affinity "$WORK/default.yaml" common-test-chart-test-app)"
if [ "$got" = "$want_anti|" ]; then ok "chart-wide affinity reaches a workload that sets none"; else bad "chart-wide default: got '$got'"; fi

[ "$fails" -eq 0 ] && echo "PASS: affinity" || { echo "FAILED: $fails"; exit 1; }
