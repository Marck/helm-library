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
#     Servarr app is a name, a uid and a port;
#   * an app that imports must MOUNT what it imports from, at the path the
#     download client reports, and it must carry the shared NAS group so it can
#     read files it did not write. Sonarr and Radarr had neither for over a
#     month: every import failed with "path does not exist or is not accessible"
#     while both apps reported Available and every torrent completed.
set -eu

DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
CHART="$DIR/../charts/servarr"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

helm dependency update "$CHART" >/dev/null 2>&1
helm template sonarr "$CHART" -f "$CHART/ci/example-values.yaml" > "$WORK/render.yaml"
helm template sonarr "$CHART" -f "$CHART/ci/example-values.yaml" \
  --set downloads.enabled=true > "$WORK/render-downloads.yaml"

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

if out="$(helm template x "$CHART" -f "$CHART/ci/example-values.yaml" \
            --set downloads.enabled=true --set app.downloadsPath=null 2>&1)"; then
  bad "downloads with no path is refused (render succeeded)"
elif echo "$out" | grep -q "downloadsPath is required"; then
  ok "downloads with no path is refused"
else
  bad "downloads with no path is refused (wrong message)"
fi

uv run --quiet --with pyyaml python3 - "$WORK/render.yaml" "$WORK/render-downloads.yaml" <<'PY'
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
# No per-app TLS Secret is derived any more. The cluster serves one wildcard
# certificate through Traefik's default TLSStore, so "<name>-tls" named a Secret
# nobody creates and Traefik logged an ERROR for every Servarr ingress on each
# config reload. The tls block must still exist WITH its hosts, or the router
# loses TLS altogether, which is the part worth asserting.
check("secretName" not in ing["spec"]["tls"][0], "no phantom TLS secret is derived")
check(bool(ing["spec"]["tls"][0].get("hosts")), "the tls block keeps its hosts")
check("forward-auth" in ing["metadata"]["annotations"]["traefik.ingress.kubernetes.io/router.middlewares"],
      "the UI is behind forward-auth by default")
pv = docs[("PersistentVolume", "sonarr-config-pv")]
check(pv["spec"]["nfs"]["path"] == "/volume1/container_configs/sonarr", "the NFS path is derived")
check(pv["spec"]["mountOptions"] == ["nolock"], "the config mount keeps nolock")
env = {e["name"]: e["value"] for e in docs[("Deployment", "sonarr-app")]["spec"]["template"]["spec"]["containers"][0]["env"]}
check(env["PUID"] == "24" and env["PGID"] == "100", "PUID/PGID are derived from app.uid")
probe = docs[("Deployment", "sonarr-app")]["spec"]["template"]["spec"]["containers"][0]["livenessProbe"]
check(probe["httpGet"]["path"] == "/", "probes hit /, never /ping (it queries SQLite)")

# ── The downloads mount, the part that was missing ──────────────────────────
# Default OFF, so nothing an existing app chart renders changes until it opts in.
check(("PersistentVolume", "sonarr-downloads-pv") not in docs,
      "downloads is off by default, so an app that does not import is unchanged")
check("/downloads" not in [m["mountPath"] for m in
      docs[("Deployment", "sonarr-app")]["spec"]["template"]["spec"]["containers"][0]["volumeMounts"]],
      "no /downloads mount unless asked for")

dl = {(d["kind"], d["metadata"]["name"]): d
      for d in yaml.safe_load_all(open(sys.argv[2])) if d}
dlpod = dl[("Deployment", "sonarr-app")]["spec"]["template"]["spec"]
mounts = {m["mountPath"] for m in dlpod["containers"][0]["volumeMounts"]}

# The path is the whole point: the app resolves the string the download client
# hands it over the API, so a tidier mountPath silently breaks every import.
check("/downloads" in mounts,
      "downloads.enabled mounts the tree at the path the download client reports")
pv = dl[("PersistentVolume", "sonarr-downloads-pv")]
check(pv["spec"]["nfs"]["path"] == "/volume1/downloads",
      "the downloads NFS path is derived from app.downloadsPath")
check(pv["spec"]["accessModes"] == ["ReadWriteMany"],
      "the downloads tree is RWM: the client writes while the importer reads")
check(pv["spec"]["nfs"]["path"] != dl[("PersistentVolume", "sonarr-media-pv")]["spec"]["nfs"]["path"],
      "downloads and media are separate exports, so one mount cannot serve both")
check(("PersistentVolumeClaim", "sonarr-downloads-pvc") in dl,
      "the downloads PVC is derived")
# A PV and PVC that disagree on capacity never bind, and the symptom is a Pending
# pod rather than anything naming the size.
dlpvc = dl[("PersistentVolumeClaim", "sonarr-downloads-pvc")]
check(pv["spec"]["capacity"]["storage"]
      == dlpvc["spec"]["resources"]["requests"]["storage"] == "200Gi",
      "the downloads PV and PVC agree on the size, so the claim can bind")
# Group-owned by the NAS group and written by the download client's uid, so the
# importer reads them only through supplementalGroups.
check(dlpod["securityContext"].get("supplementalGroups") == [100],
      "an importer carries the shared NAS group, so it can read what it did not write")

sys.exit(1 if fails else 0)
PY
rc=$?

[ "$rc" -eq 0 ] && [ "$fails" -eq 0 ] || { echo "FAILED"; exit 1; }
echo "PASS: servarr derives an app from its name/uid/port, and its auth edit verifies, runs last, and refuses without a uid"
