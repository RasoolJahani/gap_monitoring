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

Metrics used for disk panels/alerts: `node_filesystem_avail_bytes`, `node_filesystem_size_bytes` (filter `fstype=~"ext4|xfs|btrfs"`).

### Blackbox Exporter — TLS certificate probes

Production uses the **`tls_cert`** module (TCP+TLS to `host:443`; exposes `probe_ssl_earliest_cert_expiry` without requiring a valid HTTP response).

```yaml
- job_name: blackbox_ssl_expiry
  scrape_interval: 60s
  scrape_timeout: 25s
  metrics_path: /probe
  params:
    module: [tls_cert]
  static_configs:
    - targets: ["admin.gaptel.co:443"]
      labels:
        service: admin-panel
    - targets: ["gaptel.co:443"]
      labels:
        service: user-panel
    - targets: ["gaptel.co:443"]
      labels:
        service: main-page
    - targets: ["api.gaptel.co:443"]
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

**Add targets:** append more `hostname:443` lines under `static_configs`.

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
      node_filesystem_avail_bytes{fstype=~"ext4|xfs|btrfs", mountpoint!~"/etc/(resolv|hostname)"}
      / node_filesystem_size_bytes{fstype=~"ext4|xfs|btrfs", mountpoint!~"/etc/(resolv|hostname)"}
    ) * 100 > 90
  for: 5m
  labels:
    severity: warning
```

Reference copy: `alerts.example.yml`.

Validate: `docker exec gaptel-prometheus promtool check rules /etc/prometheus/alert.rules.yml`

---

## 3. Blackbox module (`blackbox.yml`)

Production SSL job uses **`tls_cert`**:

```yaml
tls_cert:
  prober: tcp
  timeout: 20s
  tcp:
    tls: true
    preferred_ip_protocol: ip4
    ip_protocol_fallback: false
```

**`https_2xx`** (HTTP GET over TLS) is kept for reference but is **not** used for production SSL expiry in current `prometheus.yml` — some endpoints (e.g. API root) return 404 and would fail HTTP probes.

Plain **`http_2xx`** is for **HTTP only** (internal microservice health checks). **`http_frontend`** probes SPA nginx on port 80.

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

**Variable:** `probe_target` (host:443 filter)

### Disk dashboard (`gaptel-disk`)

| Panel | PromQL |
| ----- | ------ |
| Disk used % | `100 - ((node_filesystem_avail_bytes{fstype=~"ext4\|xfs\|btrfs", job="node_exporter"} / node_filesystem_size_bytes{...}) * 100)` |
| Memory used % | `(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100` |

**Variable:** `instance` (node_exporter only)

### Import into Grafana

**Auto-provisioned** (default in this repo):

1. Dashboard JSON lives in `grafana/dashboards/`.
2. `docker compose up -d` → **Dashboards** → **GapTel SSL certificates** or **GapTel Disk & Memory**.

**Manual import:** Grafana → **Import** → upload `gaptel-ssl-certificates.json` or `gaptel-disk.json`.

**Grafana datasources:** Prometheus UID `gap_prometheus`, Loki UID `gap_loki` (see `grafana/provisioning/datasources/`).

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
  --data-urlencode 'query=100 - ((node_filesystem_avail_bytes{fstype=~"ext4|xfs|btrfs",mountpoint="/"} / node_filesystem_size_bytes{fstype=~"ext4|xfs|btrfs",mountpoint="/"}) * 100)'
```

Helper script: `scripts/verify-prometheus.sh`

---

## 6. Deploy checklist

```bash
cd gap-monitoring
docker compose up -d
docker compose restart prometheus blackbox-exporter
```

Confirm in Prometheus → **Status → Targets**: `node_exporter` and `blackbox_ssl_expiry` are **UP**.

*Last updated: June 2026.*
