# GapTel monitoring

Prometheus, Blackbox Exporter, and Grafana for the GapTel platform.

**Detailed docs:** [`DOCUMENTATION.md`](./DOCUMENTATION.md) · SSL/disk setup: [`docs/SSL-DISK-MONITORING.md`](./docs/SSL-DISK-MONITORING.md)

**Production** uses Docker network **`monitoring`** (this repo creates it; your app `docker-compose.yml` attaches it as `external: true`).

**Local dev** may use **`gaptel_monitoring`** via `docker-compose.dev.yml` (see example file).

## Files

| File                                 | Purpose                                                                |
| ------------------------------------ | ---------------------------------------------------------------------- |
| **`docker-compose.yml`**             | Production: Prometheus, Alertmanager, Blackbox, Node Exporter, Loki, Promtail, Grafana |
| **`docker-compose.dev.yml`**         | Local dev (gitignored — copy from example)                             |
| **`docker-compose.dev.example.yml`** | Template for local dev                                                 |
| **`prometheus.yml`**                 | Production scrape targets + alerting                                   |
| **`prometheus.dev.yml`**             | Dev scrape targets (`host.docker.internal`, etc.)                      |
| **`alert.rules.yml`**                | Prometheus alert rules (CPU, memory, JTAPI, auth, SSL, API)            |
| **`alertmanager.yml`**               | Alert routing (add Slack/email webhooks here)                          |
| **`blackbox.yml`**                   | HTTP/TCP/HTTPS SSL probe modules                                       |

## Quick start — production

```bash
cp .env.example .env
# Edit .env — set GF_SECURITY_ADMIN_PASSWORD

docker compose up -d
```

## Quick start — local development

```bash
cp docker-compose.dev.example.yml docker-compose.dev.yml
# docker-compose.dev.yml is gitignored; customize freely

docker compose -f docker-compose.dev.yml up -d
```

Then start the backend (must join external `gaptel_monitoring`):

```bash
cd ../gap_backend
docker compose -f docker-compose.dev.yml up -d
```

**Order:** monitoring first, then backend.

## URLs (dev compose only)

| Service    | URL                   |
| ---------- | --------------------- |
| Grafana    | http://localhost:3001 |
| Prometheus | http://localhost:9090 |

Production: expose Grafana via your reverse proxy; set `GF_SERVER_ROOT_URL` in `.env`.

## Dashboards

| Dashboard                                | UID                       |
| ---------------------------------------- | ------------------------- |
| GapTel overview                          | `gaptel-overview`         |
| GapTel status board (wallboard + uptime) | `gaptel-status-board`     |
| GapTel SSL certificates                  | `gaptel-ssl-certificates` |
| GapTel Disk & Memory                     | `gaptel-disk`             |
| GapTel services & logs (status + Docker) | `gaptel-services-logs`    |

**Services & logs dashboard** — same service status table as the status board; click a **Service** name (or use the dropdown) to view that container’s Docker logs in Loki. **All system logs** at the bottom always shows every container on the host.

Requires **Loki** + **Promtail** (included in `docker-compose.yml`). Promtail needs read access to `/var/run/docker.sock` and `/var/lib/docker/containers`. Log label `service` matches Prometheus probe names (`api-gateway`, `user-panel`, …); dev compose maps `frontend` → `user-panel` and `admin-frontend` → `admin-panel`.

**Status board top row (PromQL):**

| Panel               | Query                                                                                                                                                 |
| ------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| Concurrent calls    | `jtapi_concurrent_calls`                                                                                                                              |
| JTAPI status (1=up) | `jtapi_connection_status`                                                                                                                             |
| API error rate      | `100 * sum(rate(http_request_errors_total{service="api-gateway"}[5m])) / clamp_min(sum(rate(http_requests_total{service="api-gateway"}[5m])), 0.001)` |
| API P95 latency     | `histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket{service="api-gateway"}[5m])) by (le))`                                        |
| Missed call rate    | `100 * sum(rate(jtapi_calls_missed_total[1h])) / clamp_min(sum(rate(jtapi_calls_total[1h])), 0.001)`                                                  |

## Alerting

| Alert                                    | Condition                                            |
| ---------------------------------------- | ---------------------------------------------------- |
| `HighCpuUsage` / `HighMemoryUsage`       | Host > 80% for 5m (`node-exporter`)                  |
| `JtapiDisconnected`                      | `jtapi_connection_status == 0` for 1m                |
| `HighFailedLoginRate`                    | > 50% failed auth attempts for 2m                    |
| `SslCertificateExpiringSoon`             | TLS cert expires in < 14 days (blackbox `tls_cert`)      |
| `SslCertificateExpiringCritical`         | TLS cert expires in < 7 days                             |
| `DiskUsageHigh`                          | Disk > 90% on ext4/xfs/btrfs (node_exporter)             |
| `HighApiErrorRate` / `HighApiLatencyP95` | api-gateway HTTP metrics                               |
| `HighConcurrentCalls`                    | `jtapi_concurrent_calls` > 500 for 5m                    |
| `BlackboxProbeDown`                      | Any blackbox probe (except SSL expiry job) failed for 2m |

Public TLS certificates use Blackbox **`tls_cert`** module in job `blackbox_ssl_expiry` (TCP+TLS to `host:443`, not HTTP). Full setup: **[docs/SSL-DISK-MONITORING.md](docs/SSL-DISK-MONITORING.md)**.

**Same-server TLS:** `blackbox-exporter` uses `extra_hosts` so `*.gaptel.co` resolves to the host gateway (local nginx on :443) instead of the public IP (NAT hairpin timeout).

Configure notification channels in **`alertmanager.yml`** (webhook, email, etc.).

Dev: Alertmanager UI at http://localhost:9093 when using `docker-compose.dev.yml`.

## Production stack integration

**Startup order**

1. `cd gap-monitoring && docker compose up -d` (creates network `monitoring`)
2. Start your app stack (`docker compose up -d`) with `monitoring: external: true` on every scraped service

**JTAPI bridge** (`jtapi-bridge` on network `monitoring`)

| Port     | Process                                                                   |
| -------- | ------------------------------------------------------------------------- |
| **8081** | Spring REST, `/metrics`, `/api/wallboard/health` (`server.port`, default) |
| **8080** | Socket.IO only (`socketio.port`)                                          |

Prometheus / Blackbox must use **8081**, not 8080.

Fix production port mapping (both were mapped to container `8080`):

```yaml
ports:
  - "8080:8080" # Socket.IO
  - "8081:8081" # REST (was incorrectly 8081:8080)
```

Fix container healthcheck:

```yaml
healthcheck:
  test: ["CMD", "curl", "-f", "http://localhost:8081/api/wallboard/health"]
```

**Frontends** — nginx listens on **port 80** inside the container. Prometheus probes **`http://user-panel:80/`** and **`http://admin-panel:80/`** (root path; `/health` also exists after nginx config deploy).

| Compose service | Blackbox probe                 |
| --------------- | ------------------------------ |
| `user-panel`    | `http://user-panel:80/`        |
| `admin-panel`   | `http://admin-panel:80/`       |

Deploy updated `gaptel-user/nginx.conf` and `gaptel-admin/nginx.conf` (includes `/health`), then reload panels.

**Backend observability** — add to each microservice in app compose (example):

```yaml
environment:
  - OBSERVABILITY_PORT=9101 # auth-service; use 9102, 9103, … per service
```

Without `OBSERVABILITY_PORT`, Nest services have no HTTP listener and Prometheus shows them as DOWN.

**Production scrape targets** (`prometheus.yml` job `gap_backend_metrics`): `api-gateway:3000`, `auth-service:9101`, `user-service:9102`, `cucm-service:9103`, `cdr-service:9104`, `file-service:9105`, **`config-service:9106`**, `cdr-processor:3004`, **`recording-watcher:9107`**, **`asterisk-service:9108`**.

**JTAPI health probe:** production blackbox may use `/api/wallboard/health` on port 8081; dev compose may use Actuator `/health` — check your `prometheus.dev.yml` vs `prometheus.yml`.

## Networks

| Environment    | Network             | Created by                          |
| -------------- | ------------------- | ----------------------------------- |
| **Production** | `monitoring`        | `gap-monitoring/docker-compose.yml` |
| **Local dev**  | `gaptel_monitoring` | `docker-compose.dev.yml`            |

Postgres on production is already on `monitoring` as container `postgres` — no separate `postgres_net` needed there.

## Git

Default branch: **`main`**. Local `docker-compose.dev.yml` is not committed.

## Deploy to servers

Sync production files to a remote host (`docker-compose.yml`, `prometheus.yml`, `alert.rules.yml`, `alertmanager.yml`, `blackbox.yml`, `loki/`, `promtail/`, `grafana/`, `docs/`):

```bash
./scripts/rsync.sh gaptelco
./scripts/rsync.sh eghamat chitika
```

| Target     | Remote path                                             |
| ---------- | ------------------------------------------------------- |
| `eghamat`  | `/home/gaptel/mystorage/docker_apps/eghamat/monitoring` |
| `gaptelco` | `/home/gaptel/mystorage/docker_apps/gap/monitoring`     |
| `chitika`  | `/home/gaptel/mystorage/docker_apps/gap/monitoring`     |

After rsync, on the server:

```bash
cd /home/gaptel/mystorage/docker_apps/gap/monitoring   # path varies by target
docker compose up -d
docker compose restart prometheus blackbox-exporter
```

Ensure `.env` exists on the server (not synced — copy from `.env.example` once).

## Application metrics (implemented in app repos)

**`gap_jtapi_bridge`** (`/metrics` on port 8081):

| Metric                        | Type      | Description                     |
| ----------------------------- | --------- | ------------------------------- |
| `jtapi_concurrent_calls`      | Gauge     | Active wallboard calls          |
| `jtapi_connection_status`     | Gauge     | 1 = provider IN_SERVICE         |
| `jtapi_calls_total`           | Counter   | Calls started                   |
| `jtapi_calls_missed_total`    | Counter   | Inbound ended without CONNECTED |
| `jtapi_call_duration_seconds` | Histogram | Call duration (seconds)         |

**`gap_backend`** (api-gateway `:3000`, microservices `:9101`…):

| Metric                                        | Type      | Labels                                      |
| --------------------------------------------- | --------- | ------------------------------------------- |
| `http_requests_total`                         | Counter   | `method`, `route`, `status`, `status_class` |
| `http_request_duration_seconds`               | Histogram | `method`, `route`, `status_class`           |
| `http_request_errors_total`                   | Counter   | status >= 400                               |
| `auth_attempts_total` / `auth_failures_total` | Counter   | failed login / brute-force alerts           |
