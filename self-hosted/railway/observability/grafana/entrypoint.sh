#!/bin/sh

set -eu

: "${VICTORIAMETRICS_URL:?Missing required variable: VICTORIAMETRICS_URL}"

mkdir -p /etc/grafana/provisioning/datasources

cat >/etc/grafana/provisioning/datasources/convex-metrics.yml <<EOF
apiVersion: 1

datasources:
  - name: Convex Metrics
    type: prometheus
    uid: convex-metrics
    access: proxy
    url: ${VICTORIAMETRICS_URL}
    isDefault: true
    editable: false
EOF

export GF_SERVER_HTTP_PORT="${PORT:-3000}"
exec /run.sh
