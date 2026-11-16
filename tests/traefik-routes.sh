#!/usr/bin/env bash
# common.middlewares and common.ingressRoutes must hand a chart's Traefik
# configuration to the cluster unchanged.
#
# These carry match rules and regular expressions: backticks, backslashes,
# `${1}` and `&&`, inside YAML, inside a Go template, rendered through `tpl`.
# Each layer can quietly rewrite such a string, and a rule that is one character
# off still renders, still applies, and then matches nothing or everything.
#
# Rules, as relationships so the fixtures can change freely:
#
#   1. What a chart puts under `spec` and `routes` comes out deep-equal, apart
#      from references to other values, which are resolved.
#   2. Only enabled entries render, named by `name` or else by their key.
#   3. Only the traefik.io API group is emitted (Traefik v3 serves no other).
#   4. `tls: {}` survives as an empty map (it asks for the default certificate)
#      and a route without the key has no tls at all (plain HTTP).
#   5. A chart that defines neither map renders exactly what it rendered before.
#   6. A missing `spec` or `routes` fails the render with a message naming it.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"
bash tests/vendor-common.sh >/dev/null

CHART=tests/common-test-chart
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if command -v uv >/dev/null 2>&1; then RUN=(uv run --quiet --with pyyaml python -); else RUN=(python3 -); fi

cat > "$TMP/values.yaml" <<'YAML'
routeHost: login.example.com
middlewares:
  legacyFlow:
    enabled: true
    name: legacy-flow
    spec:
      redirectRegex:
        regex: '^(https?://[^/]+/if/flow/[^?]*)\??(.*)$'
        replacement: '${1}?sfe=1&${2}'
        permanent: false
  byKey:
    enabled: true
    spec:
      headers:
        customResponseHeaders:
          X-Robots-Tag: "noindex, nofollow"
  switchedOff:
    enabled: false
    spec:
      addPrefix:
        prefix: /nope
ingressRoutes:
  legacyFlow:
    enabled: true
    name: legacy-flow
    entryPoints:
      - websecure
    routes:
      - kind: Rule
        match: Host(`{{ .Values.routeHost }}`) && PathPrefix(`/if/flow/`) && HeaderRegexp(`User-Agent`, `(Version/([1-9]|1[0-5])\.[0-9.]+ (Mobile/[^ ]+ )?Safari/)|(\((iPad|iPhone|iPod)[^)]* OS ([1-9]|1[0-5])_)`) && !Query(`sfe`, `1`)
        priority: 1000
        middlewares:
          - name: legacy-flow
        services:
          - kind: TraefikService
            name: noop@internal
    tls: {}
  plainHttp:
    enabled: true
    routes:
      - kind: Rule
        match: PathPrefix(`/metrics`)
        services:
          - name: app
            port: 9100
  switchedOff:
    enabled: false
    routes: []
YAML

helm template t "$CHART" > "$TMP/before.yaml"
helm template t "$CHART" -f "$TMP/values.yaml" > "$TMP/after.yaml"

VALUES="$TMP/values.yaml" BEFORE="$TMP/before.yaml" AFTER="$TMP/after.yaml" "${RUN[@]}" <<'PYEOF'
import os, sys, yaml

values = yaml.safe_load(open(os.environ["VALUES"]))
load = lambda p: [d for d in yaml.safe_load_all(open(p)) if isinstance(d, dict)]
before, after = load(os.environ["BEFORE"]), load(os.environ["AFTER"])
fails = []
KINDS = ("Middleware", "IngressRoute")

def resolve(node):
    """What tpl should make of a value: references filled in, nothing else touched."""
    if isinstance(node, str):
        return node.replace("{{ .Values.routeHost }}", values["routeHost"])
    if isinstance(node, list):
        return [resolve(x) for x in node]
    if isinstance(node, dict):
        return {k: resolve(v) for k, v in node.items()}
    return node

# Rule 5
if any(d.get("kind") in KINDS for d in before):
    fails.append("a chart without middlewares or ingressRoutes renders Traefik resources")
rest = [d for d in after if d.get("kind") not in KINDS]
if rest != before:
    fails.append("defining middlewares or ingressRoutes changed other resources of the chart")

# Rule 3
for d in after:
    if d.get("kind") in KINDS and d.get("apiVersion") != "traefik.io/v1alpha1":
        fails.append(f"{d['kind']} {d['metadata']['name']} uses {d.get('apiVersion')}, which Traefik v3 does not serve")

for kind, key, field in (("Middleware", "middlewares", "spec"), ("IngressRoute", "ingressRoutes", "routes")):
    got = {d["metadata"]["name"]: d for d in after if d.get("kind") == kind}
    want = {(v.get("name") or k): v for k, v in values[key].items() if v.get("enabled")}
    # Rule 2
    if set(got) != set(want):
        fails.append(f"{kind}: rendered {sorted(got)}, expected the enabled entries {sorted(want)}")
        continue
    for name, entry in want.items():
        spec = got[name]["spec"]
        rendered = spec if field == "spec" else spec.get("routes")
        # Rule 1
        if rendered != resolve(entry[field]):
            fails.append(f"{kind} {name}: {field} was altered on the way through.\n  in:  {resolve(entry[field])}\n  out: {rendered}")
        if not got[name]["metadata"].get("namespace") or not got[name]["metadata"].get("labels"):
            fails.append(f"{kind} {name}: no namespace or no labels")
        if kind == "IngressRoute":
            if spec.get("entryPoints") != entry.get("entryPoints"):
                fails.append(f"IngressRoute {name}: entryPoints {spec.get('entryPoints')} != {entry.get('entryPoints')}")
            # Rule 4
            if "tls" in entry and spec.get("tls") != entry["tls"]:
                fails.append(f"IngressRoute {name}: tls {spec.get('tls')!r} != {entry['tls']!r}")
            if "tls" not in entry and "tls" in spec:
                fails.append(f"IngressRoute {name}: a tls block appeared though the chart asked for plain HTTP")

if "{{" in open(os.environ["AFTER"]).read().split("# Source: common-test-chart/templates/traefik-routes.yaml", 1)[-1]:
    fails.append("an unresolved template expression is left in the rendered routes")

for f in fails:
    print("FAIL:", f)
if fails:
    sys.exit(1)
print("ok    spec and routes pass through unchanged, references resolved, only enabled entries, traefik.io only")
PYEOF

# Rule 6
for case in "middlewares.broken.enabled=true|middlewares.broken.spec is required" \
            "ingressRoutes.broken.enabled=true|ingressRoutes.broken.routes is required"; do
  set_arg="${case%%|*}"; want="${case##*|}"
  if out="$(helm template t "$CHART" --set "$set_arg" 2>&1)"; then
    echo "FAIL: $set_arg rendered without the required field"; exit 1
  fi
  grep -qF "$want" <<<"$out" || { echo "FAIL: $set_arg failed, but not with '$want': $(tail -n 1 <<<"$out")"; exit 1; }
done
echo "ok    a missing spec or routes fails the render by name"
