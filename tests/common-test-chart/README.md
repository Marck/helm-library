# common-test-chart

Test chart that exercises the `common` library chart. Not published (lives outside
`charts/` so chart-releaser ignores it).

Run locally:

```bash
helm dependency update tests/common-test-chart
helm template test tests/common-test-chart -f tests/common-test-chart/values.yaml
```

`values.yaml` covers the common path (deployment/service/PV/PVC) plus the `hostNetwork`
and `additionalContainers` features. `values-multi-pv.yaml` covers `persistenceVolumes`.
