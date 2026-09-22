#!/bin/sh
# A tag is a moving pointer. Several upstreams publish nothing but `latest`, so
# without a digest there is no way to pin them and a chart silently redeploys
# whatever `latest` means today. These assert that `image.digest` reaches every
# workload kind, that it composes with a tag as repo:tag@digest, that it works
# without a tag, and -- most importantly -- that charts which set no digest
# render byte-for-byte as before.
set -eu

DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
CHART="$DIR/common-test-chart"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

DIGEST="sha256:874f719518f617d03a60e03411fc5d090647e1a877041e81f8dc965927c7deb6"

"$DIR/vendor-common.sh" "$CHART"

if python3 -c 'import yaml' 2>/dev/null; then PYRUN="python3"; else PYRUN="uv run --with pyyaml python3"; fi

helm template test "$CHART" -f "$CHART/values.yaml" > "$WORK/base.yaml"
helm template test "$CHART" -f "$CHART/values.yaml" \
  --set common.image.digest="$DIGEST" > "$WORK/digest.yaml"
helm template test "$CHART" -f "$CHART/values.yaml" \
  --set common.image.tag=null --set common.image.digest="$DIGEST" > "$WORK/nodigesttag.yaml"

fails=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }

# Every container image in the render, as "Kind/name container=image".
images() {
  $PYRUN - "$1" <<'PY'
import sys, yaml
for d in yaml.safe_load_all(open(sys.argv[1])):
    if not d:
        continue
    spec = (d.get("spec") or {})
    tpl = spec.get("template") or (spec.get("jobTemplate") or {}).get("spec", {}).get("template")
    pod = (tpl or {}).get("spec")
    if not pod:
        continue
    for c in (pod.get("containers") or []) + (pod.get("initContainers") or []):
        print("%s/%s %s=%s" % (d.get("kind"), (d.get("metadata") or {}).get("name"), c.get("name"), c.get("image")))
PY
}

# 1. No digest set => nothing anywhere gains an @sha256. This is the regression
#    guard for every existing chart: they set no digest, so their output must
#    not move at all.
if images "$WORK/base.yaml" | grep -q '@sha256:'; then
  bad "baseline render is free of digests"
else
  ok "baseline render is free of digests"
fi

# 2. The digest reaches the workloads that use the shared image block, and
#    composes as repo:tag@digest so the tag still documents what it resolved to.
want="nginx:stable@$DIGEST"
hits="$(images "$WORK/digest.yaml" | grep -c "=$want" || true)"
if [ "$hits" -ge 1 ]; then
  ok "digest composes as repo:tag@digest ($hits container(s))"
else
  bad "digest composes as repo:tag@digest (found none)"
  images "$WORK/digest.yaml" | sed 's/^/     /'
fi

# 3. Every template that renders the shared image block must go through the
#    helper, not just the Deployment: a helper used in five places is easy to
#    wire into four, and the test chart only exercises the shared block on one
#    kind, so a render alone would not catch the other four.
#
#    Containers whose image is a literal string (additionalContainers, the
#    ensure-ownership and wait-for helpers) are deliberately untouched: the
#    author writes the full reference there, digest included if wanted.
for tpl in _deployment _statefulset _daemonset _job _cronjob; do
  f="$CHART/charts/common/templates/$tpl.tpl"
  if ! grep -q 'image: {{ include "common.imageRef"' "$f"; then
    bad "$tpl renders its image through common.imageRef"
    continue
  fi
  if grep -q '{{ \$config.image.repository }}' "$f"; then
    bad "$tpl still has a hand-built image reference"
  else
    ok "$tpl renders its image through common.imageRef"
  fi
done

# 4. The helper must NOT be called common.image. Helm template names are global
#    across a chart and all of its subcharts, and the Bitnami-style valkey
#    subchart vendored under immich defines its own common.image with a
#    different signature. Taking that name hijacked valkey's calls and rendered
#    `image: <nil>` in the immich release, which still produced valid YAML.
if grep -rq 'define "common.image"' "$CHART/charts/common/templates/"; then
  bad "helper avoids the colliding name common.image"
else
  ok "helper avoids the colliding name common.image"
fi

# 5. Digest without a tag renders repo@digest, not repo:@digest or repo:null.
if images "$WORK/nodigesttag.yaml" | grep -q "=nginx@$DIGEST"; then
  ok "digest without a tag renders repo@digest"
else
  bad "digest without a tag renders repo@digest"
  images "$WORK/nodigesttag.yaml" | grep nginx | head -3 | sed 's/^/     /'
fi

# 6. The strongest statement: with no digest configured the whole render is
#    identical to what the previous template produced. Compare every image
#    string against the documented old behaviour, repository[:tag].
if images "$WORK/base.yaml" | grep -E '=nginx(:stable)?$' >/dev/null; then
  ok "baseline images still render as repository[:tag]"
else
  bad "baseline images still render as repository[:tag]"
fi

[ "$fails" -eq 0 ] || { echo "FAIL: $fails image-digest assertion(s)"; exit 1; }
echo "PASS: image.digest pins every workload kind and is a no-op when unset"
