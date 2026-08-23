#!/bin/sh
# The servarr chart's own tests. The properties that matter are the ones a
# passing `helm template` cannot show:
#
#   * the External-auth edit must VERIFY what it wrote — an unverified pass
#     starts a Servarr app with NO authentication behind a public Ingress;
#   * it must run LAST, after a restore/seed step, or a restored config.xml puts
#     the old authentication mode back;
#   * it must refuse rather than write a root-owned config.xml the app cannot
#     rewrite (these charts carry their uid in PUID/PGID, which nothing can read);
#   * one `app:` block must be enough — the whole point of the chart is that a
#     Servarr app is a name, a uid and a port.
set -eu

DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
CHART="$DIR/../charts/servarr"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

helm dependency update "$CHART" >/dev/null 2>&1
helm template sonarr "$CHART" -f "$CHART/ci/example-values.yaml" > "$WORK/render.yaml"

fails=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }

if out="$(helm template x "$CHART" --set app.name=x --set app.port=1 2>&1)"; then
  bad "an app with no uid is refused (render succeeded)"
elif echo "$out" | grep -q "app.uid is required"; then
  ok "an app with no uid is refused"
else
  bad "an app with no uid is refused (wrong message)"
fi

if out="$(helm template x "$CHART" -f "$CHART/ci/example-values.yaml" \
            --set externalAuth.uid=null --set podSecurityContext=null 2>&1)"; then
  echo "$out" | grep -q "set-external-auth" \
    && bad "auth with no uid anywhere is refused (rendered anyway)" \
    || ok "auth with no uid anywhere is refused"
else
  echo "$out" | grep -q "no uid" && ok "auth with no uid anywhere is refused" \
    || bad "auth with no uid anywhere is refused (wrong message)"
fi

uv run --quiet --with pyyaml python3 - "$WORK/render.yaml" <<'PY'
import sys, yaml

docs = {(d["kind"], d["metadata"]["name"]): d
        for d in yaml.safe_load_all(open(sys.argv[1])) if d}
fails = []

def check(cond, msg):
    print(("ok   " if cond else "FAIL ") + msg)
    if not cond:
        fails.append(msg)

pod = docs[("Deployment", "sonarr-app")]["spec"]["template"]["spec"]
auth = [c for c in pod["initContainers"] if c["name"] == "set-external-auth"][0]
script = auth["command"][-1]

check(pod["initContainers"][-1]["name"] == "set-external-auth",
      "the auth edit runs LAST, so a restore step cannot undo it")
check("AuthenticationMethod>External" in script, "it sets AuthenticationMethod=External")
check("""grep -q '<AuthenticationMethod>External</AuthenticationMethod>' "$CFG\"""" in script,
      "it VERIFIES the result, so a failed edit cannot start an unauthenticated app")
check(script.splitlines()[0].strip() == "set -eu",
      "it runs under set -eu, so the verify aborts the container")
check(auth["securityContext"]["runAsUser"] == 24
      and auth["securityContext"]["runAsNonRoot"] is True,
      "it writes config.xml as the app's own uid, not root")
check(auth["securityContext"]["readOnlyRootFilesystem"] is True,
      "read-only root filesystem")
check([m["mountPath"] for m in auth["volumeMounts"]] == ["/config"],
      "it mounts the config volume it edits")

# One `app:` block is enough: everything else is derived.
names = {k[1] for k in docs}
for want in ("sonarr-config-pv", "sonarr-config-pvc", "sonarr-media-pv",
             "sonarr-app", "sonarr-ingress", "sonarr-test-connection"):
    check(want in names, f"derived resource {want}")
ing = docs[("Ingress", "sonarr-ingress")]
check(ing["spec"]["rules"][0]["host"] == "sonarr.mastcloud.nl", "the hostname is derived")
check(ing["spec"]["tls"][0]["secretName"] == "sonarr-tls", "the TLS secret is derived")
check("forward-auth" in ing["metadata"]["annotations"]["traefik.ingress.kubernetes.io/router.middlewares"],
      "the UI is behind forward-auth by default")
pv = docs[("PersistentVolume", "sonarr-config-pv")]
check(pv["spec"]["nfs"]["path"] == "/volume1/container_configs/sonarr", "the NFS path is derived")
check(pv["spec"]["mountOptions"] == ["nolock"], "the config mount keeps nolock")
env = {e["name"]: e["value"] for e in docs[("Deployment", "sonarr-app")]["spec"]["template"]["spec"]["containers"][0]["env"]}
check(env["PUID"] == "24" and env["PGID"] == "100", "PUID/PGID are derived from app.uid")
probe = docs[("Deployment", "sonarr-app")]["spec"]["template"]["spec"]["containers"][0]["livenessProbe"]
check(probe["httpGet"]["path"] == "/", "probes hit /, never /ping (it queries SQLite)")

sys.exit(1 if fails else 0)
PY
rc=$?

[ "$rc" -eq 0 ] && [ "$fails" -eq 0 ] || { echo "FAILED"; exit 1; }
echo "PASS: servarr derives an app from its name/uid/port, and its auth edit verifies, runs last, and refuses without a uid"
