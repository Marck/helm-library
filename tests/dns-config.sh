#!/bin/sh
# dnsConfig exists for exactly one reason: an alert-sending workload must still
# resolve its notification host when in-cluster DNS is degraded. The failure
# that motivated it was silent — the appset-watchdog detected a real problem,
# could not resolve api.pushover.net, retried four times and gave up, so the
# alert about the outage was itself lost to the outage.
#
# A passing render proves almost nothing here, so these assert the shapes that
# actually decide whether the fallback works:
#
#   * the nameservers must be APPENDED, not substituted — the pod keeps
#     dnsPolicy ClusterFirst so cluster names still resolve through CoreDNS and
#     the extra entries are consulted only when that path fails. Emitting
#     dnsPolicy: None here would silently cut the pod off from cluster.local;
#   * a workload that asks for nothing must stay byte-identical to before, or
#     this becomes a change to every chart in the repo rather than an opt-in;
#   * searches/options must survive for the dnsPolicy: None case, where the pod
#     supplies its own resolver config in full and an omitted search path breaks
#     every short name it uses.
set -eu

DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
CHART="$DIR/common-test-chart"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

helm dependency update "$CHART" >/dev/null 2>&1
helm template test "$CHART" -f "$CHART/values.yaml" > "$WORK/render.yaml"

fails=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }

# Pull one document out of the render by resource name.
doc() {
  python3 - "$WORK/render.yaml" "$1" <<'PYDOC'
import sys
path, want = sys.argv[1], sys.argv[2]
for d in open(path).read().split("\n---\n"):
    if f"name: {want}\n" in d:
        print(d); break
PYDOC
}

# --- cronjob: appended fallback, cluster DNS preserved ----------------------
CRON="$(doc common-test-chart-test-dns-fallback-cron)"

if printf '%s' "$CRON" | grep -q "dnsConfig:"; then
  ok "cronjob renders dnsConfig"
else
  bad "cronjob renders dnsConfig"
fi

if printf '%s' "$CRON" | grep -q -- "- 1.1.1.1" && printf '%s' "$CRON" | grep -q -- "- 9.9.9.9"; then
  ok "cronjob carries both fallback nameservers"
else
  bad "cronjob carries both fallback nameservers"
fi

# The load-bearing one: no dnsPolicy emitted means the pod keeps ClusterFirst,
# so these nameservers are a fallback rather than a replacement.
if printf '%s' "$CRON" | grep -q "dnsPolicy:"; then
  bad "cronjob must NOT emit dnsPolicy when only dnsConfig is set (would drop cluster DNS)"
else
  ok "cronjob keeps default ClusterFirst (fallback is additive)"
fi

# --- deployment: explicit None carries a full resolver config ---------------
DEP="$(doc common-test-chart-test-dns-fallback-app)"

if printf '%s' "$DEP" | grep -q "dnsPolicy: None"; then
  ok "deployment honours an explicit dnsPolicy"
else
  bad "deployment honours an explicit dnsPolicy"
fi

for want in "searches:" "svc.cluster.local" "name: ndots" 'value: "2"'; do
  if printf '%s' "$DEP" | grep -q -- "$want"; then
    ok "deployment dnsConfig keeps '$want'"
  else
    bad "deployment dnsConfig keeps '$want'"
  fi
done

# --- opt-in: everything else is untouched ----------------------------------
# Any workload that did not ask for dnsConfig must not have grown one.
others="$(python3 - "$WORK/render.yaml" <<'PYSCAN'
import sys
bad = []
for d in open(sys.argv[1]).read().split("\n---\n"):
    if "dnsConfig:" in d and "dns-fallback" not in d:
        for line in d.splitlines():
            if line.strip().startswith("name: "):
                bad.append(line.strip()); break
print(" ".join(bad))
PYSCAN
)"
if [ -z "$others" ]; then
  ok "no dnsConfig leaks into workloads that did not ask for one"
else
  bad "dnsConfig leaked into: $others"
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "all dnsConfig checks passed"
else
  echo "$fails check(s) failed"; exit 1
fi
