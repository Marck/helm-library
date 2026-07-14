# common — Helm Library Chart

A reusable library chart for deploying applications in this cluster. All consumer charts declare it as a dependency and call its templates via `include`.

## Usage

Declare the dependency in your `Chart.yaml`:

```yaml
dependencies:
  - name: common
    version: 0.1.0
    repository: "file://../.exclude/library/common"
```

Run `helm dependency update` to fetch the packaged library, then call templates from your `templates/` directory.

### Minimal consumer template

```yaml
# templates/myapp.yaml
{{- $ctx := deepCopy . -}}
{{- $_ := set $ctx "Values" .Values.myapp -}}
{{ include "common.namespace" $ctx }}
---
{{ include "common.sealedsecret" (dict "Root" $ctx) }}
---
{{ include "common.pv" (dict "Root" $ctx) }}
---
{{ include "common.pvc" (dict "Root" $ctx) }}
---
{{ include "common.deployment" (dict "Root" $ctx "Component" "app") }}
---
{{ include "common.service" (dict "Root" $ctx "Component" "app") }}
---
{{ include "common.ingress" (dict "Root" $ctx) }}
```

Set `$ctx.Values` to the app-specific section of your values file, or pass `.` directly for flat charts with `fullnameOverride` set.

---

## Templates

### `common.fullname`
Returns `fullnameOverride` if set, otherwise `<Chart.Name>-<Release.Name>` (truncated to 63 chars). Set `fullnameOverride` in your values to get clean, predictable resource names.

### `common.labels`
Standard `app.kubernetes.io/*` labels (name, instance, managed-by).

### `common.namespace`
Creates a `Namespace` resource named `values.namespace` (falls back to `Release.Namespace`).

```yaml
namespace: myapp
namespaceLabels: {}          # extra labels
namespaceAnnotations: {}     # extra annotations
podSecurity:                 # Pod Security Admission labels
  enabled: true
  enforce: baseline          # privileged | baseline | restricted
  audit: restricted
  warn: restricted
nodeSelector:                # written as a scheduler.alpha…/node-selector annotation
  node-role.kubernetes.io/worker: worker
nodeSelectorEnabled: true    # set false to suppress that annotation even when
                             # nodeSelector is set (a map default can't be cleared
                             # via Helm merge) — e.g. namespaces whose pods must
                             # run cluster-wide
```

### `common.deployment`

Parameters: `Root`, `Component` (default `"app"`), `Config` (defaults to `Root.Values`)

Key values fields under `Config`:

| Field | Description |
| --- | --- |
| `image.repository` | Container image (required) |
| `image.tag` | Image tag |
| `image.pullPolicy` | `IfNotPresent` / `Always` |
| `replicaCount` | Default `1`; use `0` to scale down (zero-replica safe — does not default to 1) |
| `revisionHistoryLimit` | Default `3` |
| `strategy` | `Recreate` (default) or `RollingUpdate` |
| `rollingUpdate.maxUnavailable` | Only with `strategy: RollingUpdate` |
| `rollingUpdate.maxSurge` | Only with `strategy: RollingUpdate` |
| `command` | Container command (overrides Docker ENTRYPOINT) |
| `args` | Container args (overrides Docker CMD) |
| `resources` | Resource requests and limits (`limits`, `requests`) |
| `env` | Map of env vars — plain values, `""` for empty, or full `valueFrom` maps |
| `envFrom` | List of `secretRef`/`configMapRef` sources (tpl-evaluated) |
| `ports` | List of `{containerPort, protocol?, name?}` for multi-port containers |
| `service.port` | Used as single container port when `ports` is not set |
| `probes.liveness/readiness/startup` | See [PROBES.md](PROBES.md) |
| `volumeMounts` | List of volume mounts (raw YAML, supports `tpl`) |
| `volumes` | List of volumes (raw YAML, supports `tpl`) |
| `initContainers` | List of init containers (raw YAML) |
| `additionalContainers` | List of extra sidecar containers appended to the pod (raw YAML) |
| `imagePullSecrets` | List of image pull secrets (e.g. for private registries) |
| `securityContext` | Container-level security context |
| `podSecurityContext` | Pod-level security context |
| `automountServiceAccountToken` | Set `false` to stop mounting the SA token into pods that never call the Kubernetes API (deployment/statefulset/job/cronjob). Only rendered when explicitly set. |
| `hostNetwork` | Set `true` to share the node's network namespace (e.g. for mDNS/multicast, which the pod overlay does not pass) |
| `dnsPolicy` | DNS policy; defaults to `ClusterFirstWithHostNet` when `hostNetwork` is true, else omitted |
| `nodeSelector` | Pod node selector |
| `affinity` | Pod affinity rules |
| `tolerations` | Pod tolerations |
| `podLabels` | Extra labels merged into the pod template (e.g. to group pods across components under one Service selector) |

**Multi-port container example:**
```yaml
ports:
  - containerPort: 8096
  - containerPort: 8920
  - containerPort: 7359
    protocol: UDP
  - containerPort: 1900
    protocol: UDP
```

**RollingUpdate example:**
```yaml
strategy: RollingUpdate
rollingUpdate:
  maxUnavailable: 0
  maxSurge: 1
```

**hostNetwork + sidecar example** (e.g. an app needing mDNS on the LAN plus a helper container reached over `127.0.0.1`):
```yaml
hostNetwork: true                 # dnsPolicy defaults to ClusterFirstWithHostNet
additionalContainers:
  - name: helper
    image: example/helper:latest
    ports:
      - containerPort: 6969
imagePullSecrets:
  - name: my-registry-cred
```

**env with secretKeyRef:**
```yaml
env:
  TZ: Europe/Amsterdam
  PASSWORD:
    valueFrom:
      secretKeyRef:
        name: my-secret
        key: password
```

### `common.statefulset`

Parameters: `Root`, `Component` (default `"app"`), `Config` (defaults to `Root.Values`)

Identical to `common.deployment` but renders a `StatefulSet`. Additional fields:

| Field | Description |
| --- | --- |
| `serviceName` | Headless service name for the StatefulSet (default: `<fullname>-<component>`) |
| `updateStrategy` | StatefulSet update strategy (e.g. `RollingUpdate`) |
| `podManagementPolicy` | `OrderedReady` or `Parallel` |
| `volumeClaimTemplates` | List of VolumeClaimTemplate objects (StatefulSet-managed PVCs) |

### `common.service`

Parameters: `Root`, `Component` (default `"app"`), `Config` (defaults to `Root.Values`)

| Field | Description |
| --- | --- |
| `service.type` | `ClusterIP` (default), `LoadBalancer`, `NodePort` |
| `service.name` | Override the Service resource name (default: `<fullname>-<component>`) |
| `service.port` | Single port (used when `service.ports` is not set) |
| `service.targetPort` | Override target port for single-port services |
| `service.portName` | Port name for single-port services |
| `service.ports` | List of port objects for multi-port services |
| `service.annotations` | Extra annotations on the Service (e.g. `kube-vip.io/loadbalancerIPs`) |
| `service.selector` | Override the pod selector (default: `name` + `component`) — e.g. to target pods across multiple components via a shared `podLabels` key |
| `service.loadBalancerIP` | Request a specific LoadBalancer IP |
| `service.externalTrafficPolicy` | `Cluster` (default) or `Local` (preserves client source IP) |
| `service.loadBalancerClass` | LoadBalancer implementation class (e.g. to pick kube-vip over k3s klipper) |

**Multi-port service example:**
```yaml
service:
  type: ClusterIP
  ports:
    - name: "http"
      port: 8096
      targetPort: 8096
    - name: "udp-discovery"
      port: 7359
      protocol: UDP
      targetPort: 7359
```

**Service with targetPort override (port mapping):**
```yaml
service:
  type: LoadBalancer
  port: 8444
  targetPort: 8443
```

**Custom service name (for secondary services on the same component):**
```yaml
dnsService:
  name: myapp-dns
  type: LoadBalancer
  ports:
    - name: dns-tcp
      port: 53
      targetPort: 53
    - name: dns-udp
      port: 53
      protocol: UDP
      targetPort: 53
```
Then call: `{{ include "common.service" (dict "Root" $ctx "Component" "app" "Config" .Values.myapp.dnsService) }}`

### `common.ingress`

Parameters: `Root`

Reads from `Root.Values.ingress`:

| Field | Description |
| --- | --- |
| `ingress.enabled` | Must be `true` to render |
| `ingress.className` | `ingressClassName` value |
| `ingress.annotations` | Map of annotations |
| `ingress.hosts` | List of `{host, paths: [{path, pathType}]}` |
| `ingress.tls` | Set to `true` to enable TLS block |
| `ingress.tlsSecretName` | TLS secret name (default: `<fullname>-cert`) |
| `ingress.serviceName` | Backend service name (default: `<fullname>-app`) |
| `ingress.servicePort` | Backend service port (default: `service.port`) |

**Example:**
```yaml
ingress:
  enabled: true
  className: traefik
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt
  hosts:
    - host: myapp.mastcloud.nl
      paths:
        - path: /
          pathType: Prefix
  tls: true
  tlsSecretName: myapp-tls
  serviceName: myapp-app
  servicePort: 8096
```

### `common.pv`

Parameters: `Root`, `Component` (default `"app"`), `Config` (defaults to `Root.Values`)

Renders a PersistentVolume when either `persistence.nfs` or `persistence.hostPath` is set (and `persistence.data` is not set).

| Field | Description |
| --- | --- |
| `persistence.name` | PV name (default: `<fullname>-<component>-pv`) |
| `persistence.storageClassName` | StorageClass for binding |
| `persistence.pvCapacity` | PV capacity (falls back to `persistence.size`) |
| `persistence.size` | Used for PVC request and PV capacity if `pvCapacity` not set |
| `persistence.accessModes` | List of access modes |
| `persistence.reclaimPolicy` | `Retain`, `Delete`, etc. |
| `persistence.nfs.server` | NFS server address |
| `persistence.nfs.path` | NFS export path |
| `persistence.hostPath.path` | Host filesystem path |
| `persistence.hostPath.type` | Optional: `Directory`, `File`, `DirectoryOrCreate`, etc. |
| `persistence.mountOptions` | List of mount options (e.g. `["vers=3"]`) |

**NFS example:**
```yaml
persistence:
  name: myapp-volume0
  storageClassName: myapp-volume0
  pvCapacity: 100Mi
  size: 50Mi
  accessModes: [ReadWriteMany]
  nfs:
    server: 10.0.0.1
    path: /volume1/container_configs/myapp
  mountOptions: [vers=3]
```

### Multiple PV/PVC

Use the `persistenceVolumes` object to define multiple PersistentVolumes and PersistentVolumeClaims:

```yaml
persistenceVolumes:
  data:
    enabled: true
    nfs:
      server: 10.0.0.1
      path: /exports/data
    size: 10Gi
    accessModes:
      - ReadWriteMany
    storageClassName: ""
    reclaimPolicy: Retain
  config:
    enabled: true
    nfs:
      server: 10.0.0.1
      path: /exports/config
    size: 5Gi
    accessModes:
      - ReadWriteMany
    storageClassName: ""
    reclaimPolicy: Retain
  media:
    enabled: true
    name: custom-media-pv  # Optional: override the generated name
    pvcName: custom-media-pvc  # Optional: override the generated PVC name
    nfs:
      server: 10.0.0.1
      path: /exports/media
    size: 100Gi
    accessModes:
      - ReadWriteMany
    storageClassName: ""
    reclaimPolicy: Retain
```

**Key Features**:
- Each entry in `persistenceVolumes` creates a separate PV/PVC pair
- PV names default to `<fullname>-<key>-pv` (e.g., `my-app-data-pv`)
- PVC names default to `<fullname>-<key>-pvc` (e.g., `my-app-data-pvc`)
- Use `name` and `pvcName` to override default naming
- Set `enabled: false` to disable specific volumes
- The combination of matching `storageClassName` and explicit `volumeName` ensures the PVC binds to the correct PV

### Volume Types

The library chart supports three volume types for PersistentVolumes:

#### 1. NFS (Network File System)

Best for shared storage across multiple pods and nodes. Requires an NFS server.

```yaml
persistenceVolumes:
  shared-data:
    enabled: true
    nfs:
      server: nas.example.com
      path: /exports/shared-data
    size: 50Gi
    accessModes:
      - ReadWriteMany
    storageClassName: nfs-storage
    reclaimPolicy: Retain
```

#### 2. hostPath

Uses a directory on the host node's filesystem. Data is tied to the specific node.

**⚠️ Warning**: hostPath volumes are not portable across nodes and should only be used for node-specific data or testing.

```yaml
persistenceVolumes:
  local-cache:
    enabled: true
    hostPath:
      path: /var/lib/myapp/cache
      type: DirectoryOrCreate  # Optional: Directory, DirectoryOrCreate, File, Socket, etc.
    size: 10Gi
    accessModes:
      - ReadWriteOnce
    storageClassName: hostpath-storage
    reclaimPolicy: Delete
```

**hostPath types** (optional):
- `Directory`: Must exist
- `DirectoryOrCreate`: Create if doesn't exist
- `File`: Must exist as a file
- `FileOrCreate`: Create file if doesn't exist
- `Socket`, `CharDevice`, `BlockDevice`: Specialized types

#### 3. local

Uses a local volume mounted on a specific node. More robust than hostPath with better lifecycle management.

**Note**: Requires `nodeAffinity` to bind the pod to the node where the volume exists.

```yaml
persistenceVolumes:
  node-storage:
    enabled: true
    local:
      path: /mnt/disks/ssd1
      nodeAffinity:
        key: kubernetes.io/hostname  # Optional: defaults to kubernetes.io/hostname
        values:
          - node-1  # Specify the node name(s) where this volume exists
          - node-2
    size: 100Gi
    accessModes:
      - ReadWriteOnce
    storageClassName: local-storage
    reclaimPolicy: Retain
```

**local volume requirements**:
- The path must exist on the specified node(s)
- Pods using this PVC will be scheduled only on nodes matching the nodeAffinity
- Better than hostPath for production use as it provides proper volume lifecycle management

### Mixed Volume Types Example

You can combine different volume types in the same configuration:

```yaml
persistenceVolumes:
  # NFS for shared media
  media:
    enabled: true
    name: app-media-pv
    pvcName: app-media-pvc
    nfs:
      server: 10.0.0.1
      path: /volume1/media
    size: 500Gi
    accessModes:
      - ReadWriteMany
    storageClassName: nfs-media
    reclaimPolicy: Retain
  
  # local volume for database on specific node
  database:
    enabled: true
    name: app-db-pv
    pvcName: app-db-pvc
    local:
      path: /mnt/fast-ssd/database
      nodeAffinity:
        values:
          - db-node-1
    size: 50Gi
    accessModes:
      - ReadWriteOnce
    storageClassName: local-ssd
    reclaimPolicy: Retain
  
  # hostPath for temporary cache
  cache:
    enabled: true
    name: app-cache-pv
    pvcName: app-cache-pvc
    hostPath:
      path: /var/cache/myapp
      type: DirectoryOrCreate
    size: 10Gi
    accessModes:
      - ReadWriteOnce
    storageClassName: hostpath-cache
    reclaimPolicy: Delete
```
The combination of matching `storageClassName` and explicit `volumeName` ensures the PVC binds to the correct PV.

**hostPath example (single persistence):**
```yaml
persistence:
  name: myapp-localtime
  storageClassName: myapp-localtime
  size: 50Mi
  accessModes: [ReadOnlyMany]
  hostPath:
    path: /etc/localtime
```

### `common.pvc`

Parameters: `Root`, `Component` (default `"app"`), `Config` (defaults to `Root.Values`)

| Field | Description |
| --- | --- |
| `persistence.pvcName` | Explicit PVC name |
| `persistence.name` | Used to derive PVC name if `pvcName` not set (replaces `-pv` suffix with `-pvc`) |
| `persistence.size` | Storage request size |
| `persistence.accessModes` | List of access modes |
| `persistence.storageClassName` | StorageClass |
| `persistence.data` | If set, renders a dynamic PVC (no volumeName binding) |

When `persistence.nfs` is set, the PVC includes a `volumeName` field to explicitly bind to the matching PV.

### `common.sealedsecret`

Parameters: `Root`

Supports both a single secret (`sealedSecret`) and a list (`sealedSecrets`).

**Array form (preferred):**
```yaml
sealedSecrets:
  - enabled: true
    name: my-credentials
    scope: namespace-wide    # or cluster-wide
    type: Opaque
    templateData:
      username: AgB...encrypted...
      password: AgB...encrypted...
```

### `common.configmap`

Parameters: `Root`

Supports a single configmap or a list. See [CONFIGMAP.md](CONFIGMAP.md) for details.

### `common.annotations`

Parameters: `Root`, `Component`, `Config`

Generates pod annotations with checksums for configMaps and sealedSecrets, so pods restart on config changes. Automatically included by `common.deployment`.

### `common.serviceaccount`

Parameters: `Root`, `Config` (optional)

Renders a ServiceAccount when `serviceAccount.create` is true. `common.deployment` automatically sets `serviceAccountName` when `serviceAccount.create` or `serviceAccount.name` is set.

```yaml
serviceAccount:
  create: true
  name: ""          # defaults to the chart fullname
  annotations: {}
  automount: true
```

### `common.rbac`

Parameters: `Root`, `Config` (optional)

Renders a Role + RoleBinding (or ClusterRole + ClusterRoleBinding with `clusterWide: true`) bound to the chart's ServiceAccount.

```yaml
rbac:
  create: true
  clusterWide: true
  rules:
    - apiGroups: [""]
      resources: [nodes, pods, namespaces]
      verbs: [get, list]
    - apiGroups: [metrics.k8s.io]
      resources: [nodes, pods]
      verbs: [get, list]
```

---

## Multi-component apps

For apps with more than one deployment (e.g. WireGuard with split/full traffic), call each template multiple times with separate `Config` objects:

```yaml
{{- $splitCtx := dict "Root" . "Component" "split-traffic" "Config" .Values.splitTraffic -}}
{{- $fullCtx  := dict "Root" . "Component" "full-traffic"  "Config" .Values.fullTraffic  -}}

{{ include "common.pv"         $splitCtx }}
{{ include "common.pvc"        $splitCtx }}
{{ include "common.deployment" $splitCtx }}
{{ include "common.service"    $splitCtx }}
---
{{ include "common.pv"         $fullCtx }}
{{ include "common.pvc"        $fullCtx }}
{{ include "common.deployment" $fullCtx }}
{{ include "common.service"    $fullCtx }}
```

Each component gets its own pod labels (`app.kubernetes.io/component: split-traffic`) and the service selector uses those labels.

## Multi-volume apps

For pods with multiple PVCs, call `common.pv`/`common.pvc` once per volume by passing a `Config` containing that volume's `persistence` block, then define `volumes` and `volumeMounts` explicitly in the deployment `Config`:

```yaml
# In values.yaml
configPersistence:
  name: myapp-config
  storageClassName: myapp-config
  ...
dataPersistence:
  name: myapp-data
  storageClassName: myapp-data
  ...

volumeMounts:
  - name: myapp-config
    mountPath: /config
  - name: myapp-data
    mountPath: /data
volumes:
  - name: myapp-config
    persistentVolumeClaim:
      claimName: myapp-config-pvc
  - name: myapp-data
    persistentVolumeClaim:
      claimName: myapp-data-pvc
```

```yaml
# In template
{{ include "common.pv"  (dict "Root" $ctx "Config" (dict "persistence" .Values.myapp.configPersistence)) }}
{{ include "common.pvc" (dict "Root" $ctx "Config" (dict "persistence" .Values.myapp.configPersistence)) }}
{{ include "common.pv"  (dict "Root" $ctx "Config" (dict "persistence" .Values.myapp.dataPersistence)) }}
{{ include "common.pvc" (dict "Root" $ctx "Config" (dict "persistence" .Values.myapp.dataPersistence)) }}
{{ include "common.deployment" (dict "Root" $ctx "Component" "app") }}
```
