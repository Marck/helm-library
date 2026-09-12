#!/bin/sh
# hostNetwork and tolerations on the BATCH workloads (cronjob, job,
# backupCronJob).
#
# The three long-running helpers have supported both since the beginning. The
# batch ones silently dropped them, which is the worst shape a gap can take: a
# chart sets hostNetwork: true, the render succeeds, the manifest is valid, and
# the pod lands on the pod network anyway. Nothing fails, the values just do not
# mean what they say.
#
# The case that forced it: sampling etcd's disk-latency histograms. k3s
# publishes those on the node's loopback only, so they are unreachable from the
# pod network, and etcd runs on a control-plane node a batch pod could not be
# placed on without a toleration. Both halves were needed, and neither existed.
#
# What is asserted, and why each one is load-bearing:
#
#   * hostNetwork actually reaches the pod spec on all three helpers.
#     backupCronJob is the one to watch: it builds its own Config dict and hands
#     that to common.cronjob, so anything not explicitly forwarded is dropped on
#     the way through even when the underlying helper supports it. That is
#     exactly how dnsConfig was lost before 0.11.0.
#   * hostNetwork implies dnsPolicy ClusterFirstWithHostNet. Without it the pod
#     shares the host's network namespace while still being told to resolve as
#     if it were on the pod network, so cluster names break in a way that looks
#     like a DNS fault rather than a policy mistake.
#   * an explicit dnsPolicy still wins, or a workload that deliberately wants the
#     host's own resolver cannot say so.
#   * a workload that asks for nothing renders byte-identically. Otherwise this
#     is a change to every batch workload in every chart, not an opt-in.
set -eu

DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
CHART="$DIR/common-test-chart"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

"$DIR/vendor-common.sh" "$CHART"
helm template test "$CHART" > "$WORK/render.yaml"

if command -v uv >/dev/null 2>&1; then
  run_py() { uv run --quiet --with pyyaml python3 - "$@"; }
else
  run_py() { python3 - "$@"; }
fi

fails=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }

check() { # <suffix> <want-hostNetwork> <want-dnsPolicy|-> <want-tolerations yes|no>
  run_py "$WORK/render.yaml" "$1" "$2" "$3" "$4" <<'PY'
import sys, yaml
path, suffix, want_hn, want_dns, want_tol = sys.argv[1:6]
found = None
for d in yaml.safe_load_all(open(path)):
    if not d:
        continue
    if d.get("metadata", {}).get("name", "").endswith(suffix):
        k = d["kind"]
        found = (d["spec"]["jobTemplate"]["spec"]["template"]["spec"]
                 if k == "CronJob" else d["spec"]["template"]["spec"])
        break
if found is None:
    print(f"MISSING {suffix}")
    sys.exit(2)
hn = str(found.get("hostNetwork"))
dns = str(found.get("dnsPolicy"))
tol = "yes" if found.get("tolerations") else "no"
bad = []
if hn != want_hn:  bad.append(f"hostNetwork={hn} want {want_hn}")
if dns != want_dns: bad.append(f"dnsPolicy={dns} want {want_dns}")
if tol != want_tol: bad.append(f"tolerations={tol} want {want_tol}")
if bad:
    print("; ".join(bad))
    sys.exit(1)
PY
}

for target in "hostnet-cron CronJob" "hostnet-job Job" "hostnet-backup backupCronJob"; do
  suffix="${target% *}"; label="${target#* }"
  if out="$(check "$suffix" True ClusterFirstWithHostNet yes 2>&1)"; then
    ok "$label carries hostNetwork, the implied dnsPolicy and tolerations"
  else
    bad "$label: $out"
  fi
done

if out="$(check hostnet-cron-explicit-dns True Default no 2>&1)"; then
  ok "an explicit dnsPolicy overrides the hostNetwork default"
else
  bad "explicit dnsPolicy override: $out"
fi

if out="$(check hostnet-cron-untouched None None no 2>&1)"; then
  ok "a batch workload that asks for nothing is unchanged"
else
  bad "untouched batch workload: $out"
fi

[ "$fails" -eq 0 ] || { echo "$fails assertion(s) failed"; exit 1; }
echo "PASS: hostNetwork + tolerations reach cronjob, job and backupCronJob, and opt-in stays opt-in"
