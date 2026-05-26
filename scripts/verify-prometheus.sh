#!/usr/bin/env bash
# Quick checks after deploy (run on the monitoring server).
set -euo pipefail

PROM="${PROMETHEUS_URL:-http://127.0.0.1:9090}"

echo "=== Prometheus healthy ==="
curl -sf "${PROM}/-/healthy" && echo " OK" || { echo "FAIL: cannot reach ${PROM}"; exit 1; }

echo ""
echo "=== Rule files loaded ==="
curl -sf "${PROM}/api/v1/rules" | python3 -c "
import json,sys
d=json.load(sys.stdin)['data']['groups']
print(f'{len(d)} rule groups loaded')
for g in d:
    print(f'  - {g[\"name\"]}: {len(g[\"rules\"])} rules')
" || echo "WARN: could not list rules"

echo ""
echo "=== Blackbox SSL targets ==="
curl -sf "${PROM}/api/v1/targets" | python3 -c "
import json,sys
for t in json.load(sys.stdin)['data']['activeTargets']:
    if 'blackbox_ssl' in t['labels'].get('job',''):
        print(t['labels'].get('job'), t['health'], t['labels'].get('probe_target',''), t.get('lastError','')[:80])
"

echo ""
echo "=== Sample metrics ==="
for q in \
  'up{job=\"node_exporter\"}' \
  'probe_success{job=\"blackbox_ssl_expiry\"}' \
  'probe_ssl_earliest_cert_expiry{job=\"blackbox_ssl_expiry\"}'; do
  echo -n "$q => "
  curl -sfG "${PROM}/api/v1/query" --data-urlencode "query=${q}" | python3 -c "
import json,sys
r=json.load(sys.stdin)['data']['result']
print(len(r), 'series' if r else 'NO DATA')
"
done
