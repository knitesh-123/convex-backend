#!/bin/sh

set -eu

require_var() {
  name="$1"
  eval value="\${$name:-}"
  if [ -z "$value" ]; then
    echo "Missing required variable: $name" >&2
    exit 1
  fi
}

require_var BACKEND_METRICS_HOST

BACKEND_METRICS_SCHEME="${BACKEND_METRICS_SCHEME:-https}"
BACKEND_METRICS_PATH="${BACKEND_METRICS_PATH:-/_metrics}"
SCRAPE_INTERVAL="${SCRAPE_INTERVAL:-15s}"

if { [ -n "${BACKEND_METRICS_USERNAME:-}" ] && [ -z "${BACKEND_METRICS_PASSWORD:-}" ]; } || \
   { [ -z "${BACKEND_METRICS_USERNAME:-}" ] && [ -n "${BACKEND_METRICS_PASSWORD:-}" ]; }; then
  echo "Set both BACKEND_METRICS_USERNAME and BACKEND_METRICS_PASSWORD, or neither." >&2
  exit 1
fi

cat >/etc/victoriametrics/promscrape.yml <<EOF
scrape_configs:
  - job_name: convex
    metrics_path: ${BACKEND_METRICS_PATH}
    scheme: ${BACKEND_METRICS_SCHEME}
    scrape_interval: ${SCRAPE_INTERVAL}
    static_configs:
      - targets:
          - ${BACKEND_METRICS_HOST}
EOF

if [ -n "${BACKEND_METRICS_USERNAME:-}" ]; then
  cat >>/etc/victoriametrics/promscrape.yml <<EOF
    basic_auth:
      username: ${BACKEND_METRICS_USERNAME}
      password: ${BACKEND_METRICS_PASSWORD}
EOF
fi

exec /victoria-metrics-prod \
  -promscrape.config=/etc/victoriametrics/promscrape.yml \
  -storageDataPath=/victoria-metrics-data \
  -httpListenAddr=:${PORT:-8428}
