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
#   * drain mounted read-only: keepalived drops the track_file with a warning
#     and planned restarts lose queries again (verified in the image).
#   * a second check (extraTracks) must be its own vrrp_script, tracked by the
#     instance, start failed, and keep the same weight rules.
#   * drain weight outside (priority gap, |track.weight| - gap): a draining
#     node either keeps the address or loses it to a broken node.
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

for comp, tracked in (("vip-dns", True), ("vip-extra", True), ("vip-single", False)):
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
    check(("track_file drain {" in conf) == tracked and ("track_file {" in conf) == tracked,
          f"{comp}: drain file {'tracked' if tracked else 'absent'}")
    check("ignoring|cannot be monitored" in cm["data"]["keepalived-render.sh"], f"{comp}: render fails on dropped checks")

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
check(re.search(r'^\s*file "/drain/flag"$', dconf, re.M) is not None and re.search(r"^\s*weight -20$", dconf, re.M) is not None,
      "pair: drain file and weight -20")
vol = next((v for v in dns["volumes"] if v["name"] == "drain"), {})
hp = vol.get("hostPath", {})
check(hp.get("type") == "DirectoryOrCreate" and hp.get("path", "").startswith("/run/keepalived-drain/"), "pair: drain hostPath default")
for c in (dns["containers"][0], dns["initContainers"][0]):
    m = next((m for m in c["volumeMounts"] if m["name"] == "drain"), None)
    check(m is not None and m["mountPath"] == "/drain" and not m.get("readOnly"), f"pair: {c['name']} mounts /drain read-write")
check(not any(v["name"] == "drain" for v in single["volumes"]), "single: no drain volume")
ex = get("ConfigMap", "vip-extra")["data"]["keepalived.conf"]
exc = get("DaemonSet", "vip-extra")["spec"]["template"]["spec"]["containers"][0]
check("vrrp_script dns_public {" in ex and 'script "/usr/bin/env QUERY_NAME=example.com EXPECT_ANSWER= /usr/local/bin/dns-track.sh"' in ex,
      "extra: second vrrp_script with its own variables")
check(re.search(r"track_script \{\s*dns_ok\s*dns_public\s*\}", ex) is not None, "extra: the instance tracks both checks")
check(ex.count("init_fail") == 2 and re.search(r"^\s*interval 5$", ex, re.M) is not None, "extra: starts failed, own interval")
check("TRACK_TARGET" in {e["name"] for e in exc["env"]}, "extra: TRACK_TARGET set")
if fails:
    sys.exit(f"{len(fails)} check(s) failed")
PY

# refuse CONFIG ERROR: render a one-off template and expect the render to fail with ERROR.
refuse() {
  printf '%s\n' "$2" > "$CHART/templates/zz-keepalived-negative.yaml"
  if helm template test "$CHART" >/dev/null 2>"$WORK/err"; then
    rm -f "$CHART/templates/zz-keepalived-negative.yaml"; echo "  FAIL $1 rendered"; exit 1
  fi
  rm -f "$CHART/templates/zz-keepalived-negative.yaml"
  grep -q "$3" "$WORK/err" && echo "  ok   $1 fails the render" || { echo "  FAIL $1: wrong error"; cat "$WORK/err"; exit 1; }
}
base='"vip" "192.0.2.9" "image" (dict "repository" "x" "tag" "1") "preferredNodeIP" "192.0.2.1" "track" (dict "script" "/x" "weight" -40)'
echo "== bad weights are refused"
refuse "track weight 0" '{{ include "common.keepalived" (dict "Root" . "Config" (dict "vip" "192.0.2.9" "image" (dict "repository" "x" "tag" "1") "track" (dict "script" "/x" "weight" 0))) }}' "must be negative"
refuse "drain weight 0" "{{ include \"common.keepalived\" (dict \"Root\" . \"Config\" (dict $base \"drain\" (dict \"weight\" 0))) }}" "must be negative"
refuse "drain weight -10 (= gap)" "{{ include \"common.keepalived\" (dict \"Root\" . \"Config\" (dict $base \"drain\" (dict \"weight\" -10))) }}" "must exceed the priority gap"
refuse "extra weight 0" "{{ include \"common.keepalived\" (dict \"Root\" . \"Config\" (dict $base \"extraTracks\" (list (dict \"name\" \"p\" \"script\" \"/x\" \"weight\" 0)))) }}" "must be negative"
refuse "extra name reused" "{{ include \"common.keepalived\" (dict \"Root\" . \"Config\" (dict $base \"extraTracks\" (list (dict \"name\" \"track\" \"script\" \"/x\" \"weight\" -40)))) }}" "used twice"
refuse "drain vs extra -25" "{{ include \"common.keepalived\" (dict \"Root\" . \"Config\" (dict $base \"drain\" (dict \"weight\" -20) \"extraTracks\" (list (dict \"name\" \"p\" \"script\" \"/x\" \"weight\" -25)))) }}" "must stay under"
refuse "drain weight -30 (= |track| - gap)" "{{ include \"common.keepalived\" (dict \"Root\" . \"Config\" (dict $base \"drain\" (dict \"weight\" -30))) }}" "must stay under"
echo "ok    common.keepalived"
