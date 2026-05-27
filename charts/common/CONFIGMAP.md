# ConfigMap Template Documentation

## Overview
The `common.configmap` template provides a flexible way to create ConfigMaps in Helm charts with support for both single and multiple ConfigMaps, including custom naming.

## Features
- **Custom naming**: Specify a custom name for ConfigMaps
- **Single ConfigMap**: Simple single ConfigMap with custom or auto-generated name
- **Multiple ConfigMaps**: Support for creating multiple ConfigMaps from an array
- **Backward compatibility**: Works with existing charts using the old format

## Usage

### Single ConfigMap with Custom Name

```yaml
configmap:
  enabled: true
  name: my-custom-config  # Optional: If not specified, generates <fullname>-cm
  data:
    config.yml: |
      key: value
    app.conf: |
      setting: enabled
```

**Generated ConfigMap name**: `my-custom-config`

### Single ConfigMap with Auto-generated Name

```yaml
configmap:
  enabled: true
  data:
    config.yml: |
      key: value
```

**Generated ConfigMap name**: `<release-name>-<chart-name>-cm`

### Multiple ConfigMaps

```yaml
configmap:
  - enabled: true
    name: app-config  # Optional
    data:
      app.yml: |
        setting: value
  
  - enabled: true
    name: nginx-config  # Optional
    data:
      nginx.conf: |
        server {
          listen 80;
        }
  
  - enabled: false  # This one will be skipped
    name: disabled-config
    data:
      test.yml: |
        test: data
```

**Generated ConfigMap names**:
- `app-config` (uses custom name)
- `nginx-config` (uses custom name)
- The third ConfigMap is not created because `enabled: false`

If no name is specified in multiple configmaps, they will be auto-generated as:
- `<release-name>-<chart-name>-cm-0`
- `<release-name>-<chart-name>-cm-1`
- etc.

## Template Implementation

The template checks if `configmap` is an array:
- **If array**: Iterates through each ConfigMap definition, respecting individual `enabled` and `name` fields
- **If object**: Creates a single ConfigMap with optional custom name

## Migration Guide

### Old Format (still supported)
```yaml
configmap:
  enabled: true
  data:
    config.yml: |
      key: value
```

### New Format with Custom Name
```yaml
configmap:
  enabled: true
  name: my-custom-name
  data:
    config.yml: |
      key: value
```

No breaking changes - the old format continues to work as before.

## Examples

### Example 1: Application Configuration
```yaml
configmap:
  enabled: true
  name: vikunja-api-config
  data:
    config.yml: |
      database:
        host: postgres
        port: 5432
```

### Example 2: Multiple Service Configurations
```yaml
configmap:
  - enabled: true
    name: frontend-config
    data:
      env.js: |
        window.API_URL = 'https://api.example.com';
  
  - enabled: true
    name: backend-config
    data:
      application.properties: |
        server.port=8080
        spring.datasource.url=jdbc:postgresql://db:5432/mydb
```

### Example 3: Environment-specific Configurations
```yaml
configmap:
  - enabled: true
    name: app-config-prod
    data:
      config.json: |
        {"environment": "production", "debug": false}
  
  - enabled: true
    name: app-config-stage
    data:
      config.json: |
        {"environment": "staging", "debug": true}
```
