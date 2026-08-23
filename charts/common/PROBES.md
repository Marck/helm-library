# Probe Configuration Guide

The common deployment template supports all Kubernetes probe types: `httpGet`, `tcpSocket`, `exec`, and `grpc`.

## Overview

Probes can be configured for:
- `liveness` - Determines if the container needs to be restarted
- `readiness` - Determines if the container is ready to accept traffic
- `startup` - Determines if the application has started (useful for slow-starting apps)

## Common Parameters

All probe types support these common parameters:
```yaml
probes:
  liveness:
    enabled: true
    initialDelaySeconds: 0      # Delay before first probe
    periodSeconds: 10           # How often to perform the probe
    timeoutSeconds: 1           # Timeout for the probe
    failureThreshold: 3         # Failures before marking unhealthy
    successThreshold: 1         # Successes before marking healthy (readiness/startup only)
```

## Probe Type Examples

### 1. HTTP GET Probe

Used to check HTTP endpoints. Most common for web applications.

```yaml
probes:
  liveness:
    enabled: true
    httpGet:
      path: /health
      port: 8080              # Can be port number or port name (e.g., "http")
      scheme: HTTP            # HTTP or HTTPS
      httpHeaders:            # Optional custom headers
        - name: Custom-Header
          value: value
    initialDelaySeconds: 0
    periodSeconds: 10
    timeoutSeconds: 1
    failureThreshold: 3
```

**Example (an app with a `/health` endpoint):**
```yaml
probes:
  liveness:
    enabled: true
    httpGet:
      path: /api/v1/info
      port: http
    initialDelaySeconds: 0
    periodSeconds: 10
    timeoutSeconds: 1
    failureThreshold: 3
```

### 2. TCP Socket Probe

Used to check if a TCP port is accepting connections. Good for databases, caches, or services without HTTP endpoints.

```yaml
probes:
  liveness:
    enabled: true
    tcpSocket:
      port: 5432              # Port number or name
      host: localhost         # Optional, defaults to pod IP
    initialDelaySeconds: 0
    periodSeconds: 10
    timeoutSeconds: 1
    failureThreshold: 3
```

**Example (Redis):**
```yaml
probes:
  liveness:
    enabled: true
    tcpSocket:
      port: 6379
    initialDelaySeconds: 5
    periodSeconds: 10
    timeoutSeconds: 1
    failureThreshold: 3
```

### 3. Exec Probe

Executes a command inside the container. Useful for custom health checks.

```yaml
probes:
  liveness:
    enabled: true
    exec:
      command:
        - cat
        - /tmp/healthy
    initialDelaySeconds: 0
    periodSeconds: 10
    timeoutSeconds: 1
    failureThreshold: 3
```

**Example (PostgreSQL):**
```yaml
probes:
  liveness:
    enabled: true
    exec:
      command:
        - /bin/sh
        - -c
        - pg_isready -U postgres -d postgres -h 127.0.0.1
    initialDelaySeconds: 30
    periodSeconds: 10
    timeoutSeconds: 5
    failureThreshold: 6
```

**Example (Custom Script):**
```yaml
probes:
  readiness:
    enabled: true
    exec:
      command:
        - /bin/sh
        - -c
        - |
          if [ -f /app/ready ]; then
            exit 0
          else
            exit 1
          fi
    initialDelaySeconds: 10
    periodSeconds: 5
    timeoutSeconds: 3
    failureThreshold: 3
```

### 4. gRPC Probe

Used to check gRPC services (requires Kubernetes 1.24+).

```yaml
probes:
  liveness:
    enabled: true
    grpc:
      port: 9090
      service: my.service.v1.Health  # Optional service name
    initialDelaySeconds: 0
    periodSeconds: 10
    timeoutSeconds: 1
    failureThreshold: 3
```

**Example (gRPC Service):**
```yaml
probes:
  liveness:
    enabled: true
    grpc:
      port: 50051
    initialDelaySeconds: 5
    periodSeconds: 10
    timeoutSeconds: 2
    failureThreshold: 3
  readiness:
    enabled: true
    grpc:
      port: 50051
      service: grpc.health.v1.Health
    initialDelaySeconds: 0
    periodSeconds: 5
    timeoutSeconds: 2
    failureThreshold: 3
```

## Complete Example with Multiple Probe Types

```yaml
myapp:
  service:
    port: 3456
    portName: http
  
  probes:
    # HTTP probe for liveness
    liveness:
      enabled: true
      httpGet:
        path: /health
        port: http
      initialDelaySeconds: 10
      periodSeconds: 10
      timeoutSeconds: 2
      failureThreshold: 3
    
    # HTTP probe for readiness
    readiness:
      enabled: true
      httpGet:
        path: /ready
        port: http
      initialDelaySeconds: 5
      periodSeconds: 5
      timeoutSeconds: 2
      failureThreshold: 3
    
    # TCP probe for startup (optional)
    startup:
      enabled: true
      tcpSocket:
        port: http
      initialDelaySeconds: 0
      periodSeconds: 5
      timeoutSeconds: 1
      failureThreshold: 30  # 30 * 5s = 150s max startup time
```

## Best Practices

1. **Choose the Right Probe Type:**
   - Use `httpGet` for web services with health endpoints
   - Use `tcpSocket` for simple port availability checks
   - Use `exec` for custom health logic or when other probes don't fit
   - Use `grpc` for gRPC services

2. **Liveness vs Readiness:**
   - Liveness: Checks if the app is running (triggers restart if fails)
   - Readiness: Checks if the app can handle traffic (removes from service if fails)
   - Use both for production workloads

3. **Timing:**
   - Set `initialDelaySeconds` to allow application startup
   - Use `startup` probe for slow-starting applications
   - Keep `periodSeconds` reasonable (5-10s typical)
   - Set `failureThreshold` based on your tolerance for false positives

4. **Avoid Common Pitfalls:**
   - Don't make probes too aggressive (can cause restart loops)
   - Ensure probe endpoints are lightweight
   - Don't use expensive database queries in health checks
   - Consider using different endpoints for liveness vs readiness

## Disabling Probes

To disable a probe:
```yaml
probes:
  liveness:
    enabled: false
  readiness:
    enabled: false
  startup:
    enabled: false
```

## Migration from Old Configuration

If you have existing probe configurations without the probe type specified, they should be updated to include the probe type explicitly:

**Before (will not work):**
```yaml
probes:
  liveness:
    enabled: true
    path: /health      # ❌ Missing httpGet wrapper
    port: 8080
```

**After (correct):**
```yaml
probes:
  liveness:
    enabled: true
    httpGet:           # ✅ Correct
      path: /health
      port: 8080
```
