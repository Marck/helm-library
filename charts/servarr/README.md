# servarr

The chart behind Sonarr, Radarr, Lidarr and Prowlarr — one implementation of the
shape all four had a copy of.

## Why

After normalising the app name, port, uid and image tag, sonarr's and lidarr's
`values.yaml` were **identical bar one NetworkPolicy**: ~150 lines of probe
tuning, NFS mount options, ingress wiring and auth policy, four times over. A fix
had to be made four times, and a fix made three times is indistinguishable from
one made four — the probe change that took two rounds to land on lidarr is
exactly that failure.

## Using it

An app chart is a dependency and an identity:

```yaml
# apps/sonarr/Chart.yaml
dependencies:
  - name: servarr
    version: 0.1.0
    repository: "https://Marck.github.io/helm-library"
```

```yaml
# apps/sonarr/values.yaml
servarr:
  app:
    name: sonarr      # names every resource, the NFS directory and the hostname
    uid: 24           # unique per app (NFS squash isolation)
    port: 8989
  image:
    repository: ghcr.io/linuxserver/sonarr
    tag: "4.0.19"
```

Everything else is derived: `sonarr-config-pv(c)`, `/volume1/container_configs/sonarr`,
`sonarr.mastcloud.nl`, `sonarr-tls`, `PUID`/`PGID`, the probe ports, the gatus
endpoint, and the `set-external-auth` init container. Anything derived can be
overridden — the app's own values are merged last and win, which is how Radarr
keeps its node-local `/config` and Prowlarr keeps its legacy volume names.

`networkPolicies` and `podSecurity` stay at the TOP level of the app's
`values.yaml`: they are read by the namespace-security chart, which reads that
file directly and knows nothing about this one.

## What it renders

PV + PVC (config, and the media tree unless `media.enabled: false`), the
Deployment, its Service, the forward-auth'd Ingress, and a `helm test` pod.

## `externalAuth`

The `set-external-auth` init container lives in THIS chart, not in `common`:
`common` holds shapes any chart can use — a Deployment, a CronJob, a chown — and
one application family's authentication policy is not one of them.

It seeds `config.xml` on first boot, rewrites or inserts `AuthenticationMethod`
on later ones, then **verifies** and exits non-zero if the file does not say
`External`. That last step is the point: an unverified pass starts the app with
no authentication behind a public Ingress. It refuses to run without a uid —
these charts carry theirs in `PUID`/`PGID`, which nothing here can read, and a
root-owned `config.xml` is one the app cannot rewrite.

It is appended **last**, after the app's own init containers, so a restore step
cannot put the old authentication mode back.

## The decisions it carries

| | |
|---|---|
| Probe `/`, never `/ping` | `/ping` queries SQLite; on NFS that blocks past the probe timeout while `/` is served from memory. Measured: `ping=FAIL 10002ms` beside `root=ok 3ms`, 4444 failed readiness events on sonarr in 5.5 days vs zero on the apps probing `/` |
| Liveness is slack (10 min) | Restarting a pod stuck in NFS I/O makes it worse — the SIGTERM is never handled and s6 starts a second copy that fights the first for the same DB |
| `nolock` on the config mount | Keeps SQLite locking in the client kernel instead of over NLM. Safe only because the volume is RWO + Recreate — never copy it to the RWM media volume |
| `Recreate` | One writer at a time on the config volume |
| External auth | The UI is behind authentik's forward-auth at the edge; the app trusts the proxy. The `/api` routes are unaffected — they authenticate on `X-Api-Key`, which is what the integrations use |

