# GapTel Monitoring — Technical Documentation

Detailed companion to [`README.md`](./README.md). Prometheus, Alertmanager, Blackbox Exporter, Node Exporter, Loki, Promtail, and Grafana for the GapTel platform.

---

## 1. Stack components

| Component | Role |
| --- | --- |
| **Prometheus** | Metrics collection and alerting |
| **Alertmanager** | Alert routing (Slack, email, webhooks) |
| **Blackbox Exporter** | HTTP/TCP/TLS probes for service health and SSL expiry |
| **Node Exporter** | Host CPU, memory, disk metrics |
| **Loki + Promtail** | Docker container log aggregation |
| **Grafana** | Dashboards and visualization |

---

## 2. Networks

| Environment | Network | Created by |
| --- | --- | --- |
| Production | `monitoring` | `gap-monitoring/docker-compose.yml` |
| Local dev | `gaptel_monitoring` | `docker-compose.dev.yml` (gitignored; copy from example) |

App stacks attach with `monitoring: external: true`. **Startup order:** monitoring first, then backend/frontends.

---

## 3. Scrape jobs (production)

| Job | Targets | Module / path |
| --- | --- | --- |
| `node_exporter` | `node-exporter:9100` | host metrics |
| `gap_backend_metrics` | api-gateway, auth, user, cucm, cdr, file, config, cdr-processor, recording-watcher, asterisk | `/metrics` |
| `jtapi_bridge_metrics` | `jtapi-bridge:8081` | `/metrics` (REST port, not Socket.IO 8080) |
| `blackbox_http_health` | backend `/health` endpoints | `http_2xx` |
| `blackbox_frontend_health` | user-panel, admin-panel `:80/` | `http_frontend` |
| `blackbox_tcp_health` | nats, redis, postgres | `tcp_connect` |
| `blackbox_ssl_expiry` | public hostnames `:443` | **`tls_cert`** |

See [`prometheus.yml`](./prometheus.yml) for authoritative target lists.

---

## 4. Dashboards

| Dashboard | UID | Primary use |
| --- | --- | --- |
| GapTel overview | `gaptel-overview` | Scrape health, auth metrics |
| GapTel status board | `gaptel-status-board` | Wallboard KPIs, probe status |
| GapTel SSL certificates | `gaptel-ssl-certificates` | TLS expiry |
| GapTel Disk & Memory | `gaptel-disk` | Host disk and memory |
| GapTel services & logs | `gaptel-services-logs` | Service table + Loki logs |

SSL and disk setup details: [`docs/SSL-DISK-MONITORING.md`](./docs/SSL-DISK-MONITORING.md).

---

## 5. Application metrics

### JTAPI bridge (`/metrics` on 8081)

| Metric | Type | Description |
| --- | --- | --- |
| `jtapi_concurrent_calls` | Gauge | Active wallboard calls |
| `jtapi_connection_status` | Gauge | 1 = provider IN_SERVICE |
| `jtapi_calls_total` | Counter | Calls started |
| `jtapi_calls_missed_total` | Counter | Inbound ended without CONNECTED |
| `jtapi_call_duration_seconds` | Histogram | Call duration |

### GAP backend

| Metric | Labels |
| --- | --- |
| `http_requests_total` | method, route, status, status_class |
| `http_request_duration_seconds` | method, route, status_class |
| `http_request_errors_total` | status >= 400 |
| `auth_attempts_total` / `auth_failures_total` | login / brute-force alerts |

Microservices expose metrics on `OBSERVABILITY_PORT` (9101, 9102, …). Without it, Prometheus shows the service as DOWN.

---

## 6. Deploy

```bash
./scripts/rsync.sh gaptelco   # or eghamat, chitika
# On server:
docker compose up -d
docker compose restart prometheus blackbox-exporter
```

Ensure `.env` exists on the server (copy from `.env.example` once; not synced by rsync).

---

## 7. Related repositories

| Repo | Integration |
| --- | --- |
| `gap_backend` | Exposes `/metrics` and `/health`; joins `monitoring` network |
| `gap_jtapi_bridge` | JTAPI metrics on 8081 |
| `gaptel-user`, `gaptel-admin` | Frontend blackbox probes on port 80 |

*Last updated: June 2026.*
