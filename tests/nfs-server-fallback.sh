#!/bin/sh
# A PV may omit nfs.server and inherit global.cluster.nas.server, so a consuming
# repo records its NAS once instead of in every chart. A render that succeeds
# proves nothing here; these read the server back out of each PersistentVolume:
#
#   * an explicit nfs.server must still win, with or without the global, or the
#     change rewrites every PV in every consumer on the next library bump;
#   * an omitted one must take the global, on both PV paths (single persistence
#     and persistenceVolumes), and only on the PV that omitted it;
#   * with neither set the render must FAIL and name the key. Silently emitting
#     an empty server would only surface as a rejected sync, far from the cause;
#   * a global.cluster without nas must fail the same way, not with a nil-pointer
#     error that points at the library instead of the missing value.
set -eu

DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
CHART="$DIR/common-test-chart"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

"$DIR/vendor-common.sh" "$CHART"

fails=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }

# Print "<pv name> <nfs server>" for every PersistentVolume in a render.
servers() {
  python3 - "$1" <<'PY'
import sys
for d in open(sys.argv[1]).read().split("\n---\n"):
    if "\nkind: PersistentVolume\n" not in "\n" + d:
        continue
    name = server = None
    for line in d.splitlines():
        s = line.strip()
        if name is None and s.startswith("name: "):
            name = s[6:]
        if s.startswith("server: "):
            server = s[8:]
    print(name, server)
PY
}

single="-f $CHART/values.yaml"
multi="-f $CHART/values-multi-pv.yaml"
glob="--set global.cluster.nas.server=global-nas.example.com"

# render <outfile> <args...>
render() { out="$1"; shift; helm template test "$CHART" "$@" > "$out"; }

# --- explicit server wins ----------------------------------------------------
# shellcheck disable=SC2086
render "$WORK/s1" $single
# shellcheck disable=SC2086
render "$WORK/s2" $single $glob
if [ "$(servers "$WORK/s1")" = "$(servers "$WORK/s2")" ] && servers "$WORK/s2" | grep -q " nas.example.com$"; then
  ok "single path: explicit server unchanged by the global"
else
  bad "single path: explicit server unchanged by the global"
fi

# shellcheck disable=SC2086
render "$WORK/m1" $multi
# shellcheck disable=SC2086
render "$WORK/m2" $multi $glob
if [ "$(servers "$WORK/m1")" = "$(servers "$WORK/m2")" ] && ! servers "$WORK/m2" | grep -q "global-nas"; then
  ok "multi path: explicit servers unchanged by the global"
else
  bad "multi path: explicit servers unchanged by the global"
fi

# --- omitted server takes the global -----------------------------------------
# shellcheck disable=SC2086
render "$WORK/s3" $single $glob --set common.persistence.nfs.server=null
if [ "$(servers "$WORK/s3" | awk '{print $2}')" = "global-nas.example.com" ]; then
  ok "single path: omitted server falls back to global.cluster.nas.server"
else
  bad "single path: omitted server falls back to global.cluster.nas.server"
fi

# shellcheck disable=SC2086
render "$WORK/m3" $multi $glob --set persistenceVolumes.data.nfs.server=null
if servers "$WORK/m3" | grep -q -- "-data-pv global-nas.example.com$" \
   && [ "$(servers "$WORK/m3" | grep -c "global-nas")" -eq 1 ]; then
  ok "multi path: only the PV that omitted it takes the global"
else
  bad "multi path: only the PV that omitted it takes the global"
fi

# --- neither set: fail loudly, naming the key ---------------------------------
# expect_fail <label> <pattern> <args...>
expect_fail() {
  label="$1"; pattern="$2"; shift 2
  if helm template test "$CHART" "$@" > /dev/null 2> "$WORK/err"; then
    bad "$label (render succeeded)"
  elif grep -q -- "$pattern" "$WORK/err"; then
    ok "$label"
  else
    bad "$label (wrong error: $(head -c 300 "$WORK/err"))"
  fi
}

# shellcheck disable=SC2086
expect_fail "single path: no server and no global fails" \
  "persistence.nfs.server is required" $single --set common.persistence.nfs.server=null
# shellcheck disable=SC2086
expect_fail "multi path: no server and no global fails" \
  "persistenceVolumes.data.nfs.server is required" $multi --set persistenceVolumes.data.nfs.server=null
# shellcheck disable=SC2086
expect_fail "global.cluster without nas fails on the value, not a nil pointer" \
  "persistence.nfs.server is required" $single --set common.persistence.nfs.server=null \
  --set global.cluster.domain=example.com

[ "$fails" -eq 0 ] || { echo "$fails failure(s)"; exit 1; }
echo "all nfs server fallback tests passed"
