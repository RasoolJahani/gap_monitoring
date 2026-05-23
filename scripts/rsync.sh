#!/usr/bin/env bash
# Rsync gap-monitoring production config to one or more remote app directories.
# Usage: ./scripts/rsync.sh <target> [<target> ...]
# Run from anywhere; paths are resolved from this repo root.
#
# Syncs production files only (compose, prometheus, blackbox, grafana dashboards).
# Does not sync docker-compose.dev.yml, prometheus.dev.yml, or .env.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

declare -A REMOTE_HOSTS
declare -A REMOTE_DIRS

# Eghamat
REMOTE_HOSTS["eghamat"]="gaptel@46.245.112.27"
REMOTE_DIRS["eghamat"]="/home/gaptel/mystorage/docker_apps/eghamat/monitoring"

# Gaptelco
REMOTE_HOSTS["gaptelco"]="gaptel@46.245.112.54"
REMOTE_DIRS["gaptelco"]="/home/gaptel/mystorage/docker_apps/gap/monitoring"

# Chitika
REMOTE_HOSTS["chitika"]="gaptel@46.245.112.53"
REMOTE_DIRS["chitika"]="/home/gaptel/mystorage/docker_apps/gap/monitoring"

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 <target> [<target> ...]"
  echo "Available targets: ${!REMOTE_HOSTS[@]}"
  exit 1
fi

# Production allowlist only — no dev compose or local secrets.
SYNC_ALLOWLIST=(
  --include="docker-compose.yml"
  --include="prometheus.yml"
  --include="blackbox.yml"
  --include="grafana/"
  --include="grafana/***"
  --include=".env.example"
  --include="README.md"
  --exclude="*"
)

for target in "$@"; do
  REMOTE="${REMOTE_HOSTS[$target]:-}"
  REMOTE_DIR="${REMOTE_DIRS[$target]:-}"
  if [[ -z "$REMOTE" || -z "$REMOTE_DIR" ]]; then
    echo "Unknown target: $target" >&2
    echo "Available: ${!REMOTE_HOSTS[@]}" >&2
    exit 1
  fi

  echo ""
  echo "=== rsync target: $target (${REMOTE}:${REMOTE_DIR}) ==="
  rsync -avhP -e "ssh" "${SYNC_ALLOWLIST[@]}" ./ "${REMOTE}:${REMOTE_DIR}/"
done

echo ""
echo "Rsync finished for: $*"
