#!/bin/sh
# The init-container helpers (ensureOwnership, waitFor, servarrExternalAuth) are
# only useful if they also do NOT fire where they would break a pod, and if their
# refusals actually refuse — neither of which `helm template` alone can assert (a
# passing render proves nothing). The shapes that matter:
#
#   * a second component with its own Config must not inherit the main
#     workload's paths — it would mount a volume it never declared, and the pod
#     is rejected at admission, not at render;
#   * enabled with no paths, or no uid to inherit, must FAIL the render rather
#     than produce an init container that chowns nothing;
#   * the fix must run BEFORE the chart's own init containers, or a seeding step
#     hits the directory while it is still root-owned;
#   * a waitFor must be BOUNDED — the hand-rolled loop this replaces was an
#     `until nc -z`, which leaves a pod in Init forever with nothing to read when
#     the dependency never comes up;
#
# (The Servarr auth edit used to live here too. It is application policy, not a
# library shape, so it moved to the servarr chart — see tests/servarr.sh.)
set -eu

DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
CHART="$DIR/common-test-chart"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

helm dependency update "$CHART" >/dev/null 2>&1
helm template test "$CHART" -f "$CHART/values.yaml" > "$WORK/render.yaml"

fails=0
ok()   { echo "ok   $1"; }
bad()  { echo "FAIL $1"; fails=$((fails + 1)); }

# Renders that must FAIL: helm template exits non-zero and says why.
render_must_fail() {
  desc="$1"; want="$2"; shift 2
  if out="$(helm template test "$CHART" --set "$@" 2>&1)"; then
    bad "$desc (render succeeded)"
  elif echo "$out" | grep -q "$want"; then
    ok "$desc"
  else
    bad "$desc (failed, but not with '$want')"
  fi
}

render_must_fail "enabled with no paths is refused" "paths is empty" \
  "bareOwnership.enabled=true,bareOwnership.uid=1000"
render_must_fail "no uid to inherit is refused" "no uid" \
  "bareOwnership.enabled=true,bareOwnership.paths[0].volume=v,bareOwnership.paths[0].mountPath=/v"
render_must_fail "a waitFor shorter than its own interval is refused" "never run twice" \
  "bareWait.timeoutSeconds=2,bareWait.intervalSeconds=5,bareWait.targets[0].host=db,bareWait.targets[0].port=5432"
render_must_fail "a waitFor target with no port is refused" "needs a port" \
  "bareWait.targets[0].host=db"

uv run --quiet --with pyyaml python3 - "$WORK/render.yaml" <<'PY'
import sys, yaml

docs = {d["metadata"]["name"]: d for d in yaml.safe_load_all(open(sys.argv[1])) if d}
fails = []

def check(cond, msg):
    print(("ok   " if cond else "FAIL ") + msg)
    if not cond:
        fails.append(msg)

def pod(name):
    d = docs[name]
    if d["kind"] == "CronJob":
        return d["spec"]["jobTemplate"]["spec"]["template"]["spec"]
    return d["spec"]["template"]["spec"]

# The main workload takes uid/gid from its podSecurityContext.
app = pod("common-test-chart-test-owned-app")
init = app["initContainers"]
check(init[0]["name"] == "ensure-ownership",
      "the ownership fix runs before the chart's own init containers")
check(init[1]["name"] == "seed-config", "the chart's own init containers still run")
check("chown 27:100 /config" in init[0]["command"][-1],
      "uid/gid are inherited from podSecurityContext (%s)" % init[0]["command"][-1])
check(init[0]["securityContext"]["capabilities"] == {"drop": ["ALL"], "add": ["CHOWN", "FOWNER"]},
      "root, but only CHOWN and FOWNER")
check(init[0]["securityContext"]["allowPrivilegeEscalation"] is False
      and init[0]["securityContext"]["readOnlyRootFilesystem"] is True,
      "no privilege escalation, read-only root filesystem")
check(app["securityContext"]["runAsUser"] == 27 and app["securityContext"]["runAsNonRoot"] is True,
      "the workload itself stays unprivileged")
check([m["mountPath"] for m in init[0]["volumeMounts"]] == ["/config"],
      "it mounts only the paths it was given")

# Per-path overrides, a mode, and several paths in one container.
cron = pod("common-test-chart-test-owned-backup")
cmd = cron["initContainers"][0]["command"][-1]
check("chown 65534:100 /backup" in cmd and "chmod 0700 /backup" in cmd,
      "an explicit gid and a mode are applied")
check("chown 20:100 /backup2" in cmd, "a per-path uid overrides the pod default")
check(cmd.index("/backup ") < cmd.index("/backup2"), "paths are applied in order")

# A second component with its own Config must NOT inherit.
agent = pod("common-test-chart-test-node-agent")
check(not agent.get("initContainers"),
      "a component with its own Config does not inherit the main workload's paths")

# Workloads that never asked for it are untouched.
plain = pod("common-test-chart-test-automount-cron")
check(not plain.get("initContainers"), "a workload without ensureOwnership is unchanged")

# waitFor: bounded, one container for several targets, ordered after the chown.
waiting = pod("common-test-chart-test-waiting-app")
names = [c["name"] for c in waiting["initContainers"]]
check(names == ["ensure-ownership", "wait-for-deps", "migrate"],
      "ownership, then the wait, then the chart's own (%s)" % names)
wait = waiting["initContainers"][1]
script = wait["command"][-1]
check("wait_for test-postgresql 5432 300 5" in script
      and "wait_for test-redis 6379 60 5" in script,
      "several targets share one init container, each with its own bound")
check("until" not in script and "unreachable after" in script,
      "the wait is BOUNDED and says which dependency never answered")
check(wait["securityContext"]["runAsUser"] == 11
      and wait["securityContext"]["capabilities"] == {"drop": ["ALL"]},
      "the wait runs as the workload's uid with no capabilities")
check(":" not in wait["image"].split(":")[-1] and wait["image"] != "busybox:latest",
      "the wait image is pinned, not :latest (%s)" % wait["image"])

sys.exit(1 if fails else 0)
PY
rc=$?

if [ "$rc" -ne 0 ] || [ "$fails" -ne 0 ]; then
  echo "FAILED"
  exit 1
fi
echo "PASS: the init-container helpers fire where they should, and refuse where they would break a pod"
