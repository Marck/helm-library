#!/bin/sh
# common.keepalived renders a VRRP pair that can actually fail over.
#
# Each assertion is a way the render can look fine and still not work, all of
# them found the hard way on the adguard DNS VIP (helm-charts task #482):
#   * SETGID missing: keepalived's setgroups() before the track script fails,
#     the child exits 0, every check "succeeds" and the address never moves.
#   * nodeSelector inherited: one member, no failover.
#   * RollingUpdate: one template change restarts every holder back to back.
#   * weight >= 0: a failing node goes FAULT and drops the address.
#   * a single holder with no track must not render an empty track_script.
set -eu

DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
CHART="$DIR/common-test-chart"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

"$DIR/vendor-common.sh" "$CHART"
# A chart-level nodeSelector, so "the pair clears the inherited one" is tested
# against something that would actually be inherited.
helm template test "$CHART" --set nodeSelector.inherited=yes > "$WORK/render.yaml"

if python3 -c 'import yaml' 2>/dev/null; then PYRUN() { python3 "$@"; }
else PYRUN() { uv run --quiet --with pyyaml python3 "$@"; }; fi

PYRUN - "$WORK/render.yaml" <<'PY'
import re, sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if isinstance(d, dict)]
fails = []
def check(ok, msg):
    print(("  ok   " if ok else "  FAIL ") + msg)
    if not ok: fails.append(msg)
def get(kind, name):
    return next((d for d in docs if d["kind"] == kind and d["metadata"]["name"].endswith("-" + name)), None)

for comp, tracked in (("vip-dns", True), ("vip-single", False)):
    ds, cm = get("DaemonSet", comp), get("ConfigMap", comp)
    check(ds is not None and cm is not None, f"{comp}: DaemonSet and ConfigMap render")
    if ds is None or cm is None: continue
    spec = ds["spec"]["template"]["spec"]
    main, init = spec["containers"][0], spec["initContainers"][0]
    conf = cm["data"]["keepalived.conf"]
    check(spec.get("hostNetwork") is True, f"{comp}: hostNetwork")
    check(ds["spec"]["updateStrategy"]["type"] == "OnDelete", f"{comp}: OnDelete")
    check(sorted(main["securityContext"]["capabilities"]["add"]) == ["NET_ADMIN", "NET_RAW", "SETGID"],
          f"{comp}: NET_ADMIN, NET_RAW and SETGID")
    check(not init["securityContext"]["capabilities"].get("add"), f"{comp}: init container adds nothing")
    check("@IFACE@" in conf and "@PRIORITY@" in conf and "{{" not in conf, f"{comp}: per-node placeholders only")
    check(re.search(r"^\s*nopreempt\b", conf, re.M) is None, f"{comp}: preemption on")
    check(("track_script" in conf) == tracked and ("vrrp_script" in conf) == tracked,
          f"{comp}: track script {'present' if tracked else 'absent'}")
    check(cm["data"]["keepalived-render.sh"].startswith("#!/bin/sh"), f"{comp}: render script ships")

dns = get("DaemonSet", "vip-dns")["spec"]["template"]["spec"]
single = get("DaemonSet", "vip-single")["spec"]["template"]["spec"]
dconf = get("ConfigMap", "vip-dns")["data"]["keepalived.conf"]
check(not dns.get("nodeSelector"), "pair: no nodeSelector (inherited one cleared)")
check(single.get("nodeSelector") == {"node-role.kubernetes.io/worker": "worker"}, "single: explicit nodeSelector kept")
check(re.search(r"^\s*weight -40$", dconf, re.M) is not None and "init_fail" in dconf, "pair: weight -40 and init_fail")
check("vrrp_instance DNS {" in dconf and "vrrp_script dns_ok {" in dconf, "pair: instance and script names")
check("192.0.2.2/32 dev @IFACE@" in dconf, "pair: vip rendered")
env = {e["name"]: e for e in dns["containers"][0]["env"]}
check(env["TRACK_TARGET"]["valueFrom"]["fieldRef"]["fieldPath"] == "status.hostIP", "pair: TRACK_TARGET is the node IP")
check(env["EXPECT_ANSWER"]["value"] == "192.0.2.12", "pair: track env passed through")
check([s["name"] for s in dns.get("imagePullSecrets", [])] == ["pull"], "pair: pull secret")
if fails:
    sys.exit(f"{len(fails)} check(s) failed")
PY

echo "== weight >= 0 is refused"
cat > "$WORK/neg.yaml" <<'Y'
{{ include "common.keepalived" (dict "Root" . "Config" (dict "vip" "192.0.2.9" "image" (dict "repository" "x" "tag" "1") "track" (dict "script" "/x" "weight" 0))) }}
Y
cp "$WORK/neg.yaml" "$CHART/templates/zz-keepalived-negative.yaml"
if helm template test "$CHART" >/dev/null 2>"$WORK/err"; then
  rm -f "$CHART/templates/zz-keepalived-negative.yaml"; echo "  FAIL weight 0 rendered"; exit 1
fi
rm -f "$CHART/templates/zz-keepalived-negative.yaml"
grep -q "must be negative" "$WORK/err" && echo "  ok   weight 0 fails the render" || { echo "  FAIL wrong error"; cat "$WORK/err"; exit 1; }
echo "ok    common.keepalived"
