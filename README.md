# helm-library

Helm library charts for use with [helm-charts](https://github.com/Marck/helm-charts).

## Usage

```bash
helm repo add marck-library https://Marck.github.io/helm-library
helm repo update
```

In `Chart.yaml`:

```yaml
dependencies:
  - name: common
    version: "0.3.0"
    repository: "https://Marck.github.io/helm-library"
```

## Charts

| Chart | Type | Description |
|-------|------|-------------|
| [common](charts/common/README.md) | library | Reusable deployment/service/ingress/PV/PVC/network-policy templates |

## Releasing

Bump `version` in `charts/common/Chart.yaml` and push to `main`.
The chart-releaser Action publishes the new version to GitHub Pages automatically.
