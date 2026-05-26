# SSL certificate & disk monitoring setup

Stack: **Prometheus** + **Blackbox Exporter** (SSL) + **Node Exporter** (disk) + **Grafana**.

---

## 1. Prometheus (`prometheus.yml`)

### Node Exporter (port 9100)

```yaml
- job_name: node_exporter
  scrape_interval: 15s
  static_configs:
    - targets: ["node-exporter:9100"]
      labels:
        category: infrastructure
        service: host
        instance: host
```

Metrics used for disk panels/alerts: `node_filesystem_avail_bytes`, `node_filesystem_size_bytes` (filter `fstype=~"ext4|xfs"`).

### Blackbox Exporter — HTTPS SSL probes

Blackbox runs the **`https_2xx`** module (HTTPS variant of `http_2xx`: requires TLS, exposes `probe_ssl_earliest_cert_expiry`).

```yaml
- job_name: blackbox_ssl_expiry
  scrape_interval: 60s
  scrape_timeout: 25s
  metrics_path: /probe
  params:
    module: [https_2xx]
  static_configs:
    - targets: ["https://admin.gaptel.co/"]
      labels:
        service: admin-panel
    - targets: ["https://gaptel.co/"]
      labels:
        service: user-panel
    - targets: ["https://api.gaptel.co/health"]
      labels:
        service: api-gateway
  relabel_configs:
    - source_labels: [__address__]
      target_label: __param_target
    - target_label: __address__
      replacement: blackbox-exporter:9115
    - source_labels: [__param_target]
      target_label: probe_target
```

**Add targets:** append more `https://your-host/` lines under `static_configs`.

**Same-server deploy:** in `docker-compose.yml`, map public hostnames to the host gateway so probes hit local nginx (not NAT hairpin):

```yaml
blackbox-exporter:
  extra_hosts:
    - "admin.gaptel.co:host-gateway"
    - "gaptel.co:host-gateway"
    - "api.gaptel.co:host-gateway"
```

Reload: `docker compose restart prometheus blackbox-exporter` or `curl -X POST http://localhost:9090/-/reload`.

---

## 2. Alert rules (`alert.rules.yml`)

Mounted in Prometheus as `/etc/prometheus/alert.rules.yml` (see `rule_files` in `prometheus.yml`).

### SSL — expires in &lt; 14 days

```yaml
- alert: SslCertificateExpiringSoon
  expr: |
    (
      probe_ssl_earliest_cert_expiry{job=~"blackbox_ssl.*"} - time()
    ) / 86400 < 14
  for: 1h
  labels:
    severity: warning
```

### Disk — usage &gt; 90%

```yaml
- alert: DiskUsageHigh
  expr: |
    100 - (
      node_filesystem_avail_bytes{fstype=~"ext4|xfs", mountpoint!~"/etc/(resolv|hostname)"}
      / node_filesystem_size_bytes{fstype=~"ext4|xfs", mountpoint!~"/etc/(resolv|hostname)"}
    ) * 100 > 90
  for: 5m
  labels:
    severity: warning
```

Reference copy: `alerts.example.yml`.

Validate: `docker exec gaptel-prometheus promtool check rules /etc/prometheus/alert.rules.yml`

---

## 3. Blackbox module (`blackbox.yml`)

```yaml
https_2xx:
  prober: http
  timeout: 20s
  http:
    valid_http_versions: ['HTTP/1.1', 'HTTP/2.0']
    valid_status_codes: [200, 301, 302, 303, 307, 308, 404]
    method: GET
    preferred_ip_protocol: ip4
    fail_if_ssl: false
    fail_if_not_ssl: true
```

Plain `http_2xx` is for **HTTP only** (internal health checks). Use **`https_2xx`** for public HTTPS + certificate expiry.

---

## 4. Grafana dashboards

Two separate dashboards (no mixed SSL + disk panels):

| Dashboard | File | UID | Content |
| --------- | ---- | --- | ------- |
| **GapTel SSL certificates** | `gaptel-ssl-certificates.json` | `gaptel-ssl-certificates` | Cert expiry, days left, probe status, TLS version |
| **GapTel Disk & Memory** | `gaptel-disk.json` | `gaptel-disk` | Disk usage %, mountpoint table, memory used % |

### SSL dashboard (`gaptel-ssl-certificates`)

| Panel | PromQL |
| ----- | ------ |
| Days left | `(probe_ssl_earliest_cert_expiry{job="blackbox_ssl_expiry"} - time()) / 86400` |
| Probe OK | `probe_success{job="blackbox_ssl_expiry"}` |

**Variable:** `probe_target` (HTTPS URL filter)

### Disk dashboard (`gaptel-disk`)

| Panel | PromQL |
| ----- | ------ |
| Disk used % | `100 - ((node_filesystem_avail_bytes{fstype=~"ext4\|xfs", job="node_exporter"} / node_filesystem_size_bytes{...}) * 100)` |
| Memory used % | `(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100` |

**Variable:** `instance` (node_exporter only)

### Import into Grafana

**Auto-provisioned** (default in this repo):

1. Dashboard JSON lives in `grafana/dashboards/`.
2. `docker compose up -d` → **Dashboards** → **GapTel SSL certificates** or **GapTel Disk & Memory**.

**Manual import:** Grafana → **Import** → upload `gaptel-ssl-certificates.json` or `gaptel-disk.json`.

---

## 5. Quick verification

```bash
# Prometheus targets
curl -s 'http://localhost:9090/api/v1/targets' | jq '.data.activeTargets[] | select(.labels.job|test("node_exporter|blackbox_ssl")) | {job:.labels.job, health:.health}'

# SSL days remaining (example)
curl -sG 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=(probe_ssl_earliest_cert_expiry{job="blackbox_ssl_expiry"} - time()) / 86400'

# Disk used %
curl -sG 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=100 - ((node_filesystem_avail_bytes{fstype=~"ext4|xfs",mountpoint="/"} / node_filesystem_size_bytes{fstype=~"ext4|xfs",mountpoint="/"}) * 100)'
```

---

## 6. Deploy checklist

```bash
cd gap-monitoring
docker compose up -d
docker compose restart prometheus blackbox-exporter
```

Confirm in Prometheus → **Status → Targets**: `node_exporter` and `blackbox_ssl_expiry` are **UP**.
