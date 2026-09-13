#!/usr/bin/env bash
# common.ingress must emit spec.tls[].secretName ONLY when the chart asks for one.
#
# It used to default to "<fullname>-cert". On a cluster that serves one wildcard
# certificate through Traefik's default TLSStore, no app keeps a per-host Secret,
# so every Ingress advertised a name that did not exist and Traefik logged
#   Error configuring TLS: secret <ns>/<name> does not exist
# once per ingress per config reload. 30 had accumulated, and that volume of ERROR
# is what hides a real one.
#
# Asserts BOTH directions, because each is a different regression: omitted when
# unset, and still emitted verbatim when a chart genuinely owns a certificate.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"
bash tests/vendor-common.sh >/dev/null

CHART=tests/common-test-chart
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fails=0
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }

if command -v uv >/dev/null 2>&1; then RUN=(uv run --with pyyaml python -); else RUN=(python3 -); fi

# sso.mode=none keeps the chart's own SSO invariant satisfied: this test is about
# the TLS block, and the forward-auth wall has its own suite (tests/sso-negative.sh).
HOSTARGS=(--set ingress.enabled=true --set ingress.tls=true
          --set sso.enforce=false --set sso.mode=none
          --set 'ingress.hosts[0].host=t.example.com'
          --set 'ingress.hosts[0].paths[0].path=/'
          --set 'ingress.hosts[0].paths[0].pathType=Prefix')

# `python -` reads its PROGRAM from stdin, so the rendered YAML must arrive by
# path rather than by pipe. Same convention as the repo's other tests.
tls_of() {  # $@ = extra --set args -> one line per Ingress tls entry
  helm template t "$CHART" "${HOSTARGS[@]}" "$@" > "$TMP/render.yaml"
  RENDER="$TMP/render.yaml" "${RUN[@]}" <<'PYEOF'
import os, yaml
for d in yaml.safe_load_all(open(os.environ["RENDER"])):
    if d and d.get("kind") == "Ingress":
        for t in (d.get("spec", {}).get("tls") or []):
            print(d["metadata"]["name"], "secretName=" + str(t.get("secretName")), "hosts=" + str(bool(t.get("hosts"))))
PYEOF
}

# 1. Unset: no Ingress may carry a secretName, and the tls block must keep its
#    hosts, or the router loses TLS altogether.
out="$(tls_of)"
[ -n "$out" ] || bad "no Ingress with a tls block rendered, so this test proves nothing"
echo "$out" | grep -q "secretName=None" || bad "secretName was emitted without tlsSecretName being set: $out"
echo "$out" | grep -q "hosts=True"     || bad "the tls block lost its hosts, which drops TLS from the router: $out"
case "$out" in *-cert*) bad "the retired <fullname>-cert default is still generated: $out" ;; esac

# 2. Set: emitted verbatim. The fix must not become "never emit a secretName".
out2="$(tls_of --set ingress.tlsSecretName=my-real-cert)"
echo "$out2" | grep -q "secretName=my-real-cert" || bad "an explicit tlsSecretName was dropped: $out2"

[ "$fails" -eq 0 ] || exit 1
echo "PASS: secretName is opt-in, the tls block keeps its hosts, and an explicit name survives"
