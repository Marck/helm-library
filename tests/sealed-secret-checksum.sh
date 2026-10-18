#!/bin/sh
# A reseal must roll the pods that read the secret, and nothing else.
#
# common.annotations has checksummed secrets since 0.3.0, but only from
# .Values.secrets and from a COMPONENT-level sealedSecrets. A chart that
# declares its sealed secrets at the ROOT (common.sealedsecret (dict "Root" .),
# so .Values.sealedSecrets) and renders its workloads with a per-component
# Config matched neither input, so no checksum/secrets was emitted at all.
#
# The consequence is the invisible kind of drift. On 2026-10-16 a resealed peer
# list and a narrowed AllowedIPs in apps/wireguard were live in git and reported
# Synced by ArgoCD while the running pods kept serving the old env, because env
# is read once at container start.
#
# Asserting the annotation merely EXISTS would not catch that. What matters is
# that its value MOVES when a sealed value moves, and holds still otherwise, so
# every assertion below renders twice and compares.
set -eu

DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
CHART="$DIR/common-test-chart"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

"$DIR/vendor-common.sh" "$CHART"

# Root-level sealed secrets, the shape every chart in helm-charts uses.
# tunnel-config feeds env to the two consumers; ghcr-pull is an image pull
# credential, read at pull time, so it opts out of the checksum entirely.
cat > "$WORK/base.values.yaml" <<'YAML'
sealedSecrets:
  - name: tunnel-config
    enabled: true
    includeChecksumInControllers:
      - sealed-app
      - sealed-sts
      - sealed-ds
    templateData:
      peer-names: AgABASECIPHERTEXT
  - name: ghcr-pull
    enabled: true
    includeInChecksum: false
    templateData:
      .dockerconfigjson: AgAPULLCREDENTIAL
YAML
sed 's/AgABASECIPHERTEXT/AgARESEALEDCIPHERTEXT/' "$WORK/base.values.yaml" > "$WORK/resealed.values.yaml"
sed 's/AgAPULLCREDENTIAL/AgAPULLCREDENTIALROTATED/' "$WORK/base.values.yaml" > "$WORK/pull.values.yaml"

render() { helm template test "$CHART" -f "$CHART/values.yaml" "$@"; }
render -f "$WORK/base.values.yaml"                            > "$WORK/base.yaml"
render -f "$WORK/resealed.values.yaml"                        > "$WORK/resealed.yaml"
render -f "$WORK/pull.values.yaml"                            > "$WORK/pull.yaml"
# An unrelated knob must not move it, or the annotation is useless noise.
render -f "$WORK/base.values.yaml" --set nodeSelector.tier=chart > "$WORK/unrelated.yaml"
# No sealed secrets at all must emit no key, not a constant hash of nothing.
render                                                        > "$WORK/none.yaml"

if python3 -c 'import yaml' 2>/dev/null; then PYRUN() { python3 "$@"; }
else PYRUN() { uv run --quiet --with pyyaml python3 "$@"; }; fi

PYRUN - "$WORK" <<'PY'
import sys, yaml

KEY = "checksum/secrets"
work = sys.argv[1]
# Deployment, StatefulSet and DaemonSet. common.cronjob and common.job call no
# annotations helper at all, by design: a batch pod re-reads the Secret on each
# run, and an annotation on a CronJob pod template rolls nothing.
CONSUMERS = ["common-test-chart-test-sealed-app",
             "common-test-chart-test-sealed-sts",
             "common-test-chart-test-sealed-ds"]
EXCLUDED = "common-test-chart-test-sealed-pull-only"

def sums(name):
    out = {}
    for d in yaml.safe_load_all(open(f"{work}/{name}.yaml")):
        if not isinstance(d, dict) or d.get("kind") not in ("Deployment", "CronJob", "DaemonSet", "StatefulSet", "Job"):
            continue
        spec = d["spec"]
        if d["kind"] == "CronJob":
            spec = spec["jobTemplate"]["spec"]
        ann = (spec["template"]["metadata"].get("annotations") or {})
        out[d["metadata"]["name"]] = ann.get(KEY)
    return out

base, resealed, pull = sums("base"), sums("resealed"), sums("pull")
unrelated, none = sums("unrelated"), sums("none")

fails = []
def check(ok, msg):
    print(("ok   " if ok else "FAIL ") + msg)
    if not ok: fails.append(msg)

for c in CONSUMERS:
    check(c in base, f"{c} renders")
    check(bool(base.get(c)), f"{c} carries {KEY} from a ROOT-level sealedSecret")

check(len({base[c] for c in CONSUMERS}) == 1,
      "both consumers hash the same secret to the same value")

for c in CONSUMERS:
    check(resealed.get(c) != base.get(c),
          f"{c} checksum MOVES on a reseal (was {base.get(c)})")
    check(unrelated.get(c) == base.get(c),
          f"{c} checksum holds still on an unrelated values change")

check(base.get(EXCLUDED) is None,
      f"{EXCLUDED} is scoped out by includeChecksumInControllers")
for c in CONSUMERS:
    check(pull.get(c) == base.get(c),
          f"{c} is not rolled by rotating an includeInChecksum: false pull credential")

check(all(v is None for v in none.values()),
      "a chart with no sealed secrets emits no checksum/secrets at all")

if fails:
    sys.exit(f"FAIL: {len(fails)} sealed-secret checksum assertion(s)")
print("PASS: root-level sealedSecrets roll their readers on a reseal")
PY
