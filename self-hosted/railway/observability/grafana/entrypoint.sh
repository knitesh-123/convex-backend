#!/bin/sh

set -eu

: "${VICTORIAMETRICS_URL:?Missing required variable: VICTORIAMETRICS_URL}"

GF_PATHS_DATA="${GF_PATHS_DATA:-/data}"
GF_PATHS_LOGS="${GF_PATHS_LOGS:-$GF_PATHS_DATA/logs}"
GF_PATHS_PLUGINS="${GF_PATHS_PLUGINS:-$GF_PATHS_DATA/plugins}"

export GF_PATHS_DATA
export GF_PATHS_LOGS
export GF_PATHS_PLUGINS

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

mkdir -p "$GF_PATHS_DATA" "$GF_PATHS_LOGS" "$GF_PATHS_PLUGINS"
chown -R 472:0 "$GF_PATHS_DATA" "$GF_PATHS_LOGS" "$GF_PATHS_PLUGINS" /etc/grafana/provisioning /var/lib/grafana/dashboards
chmod -R u+rwX,g+rwX "$GF_PATHS_DATA" "$GF_PATHS_LOGS" "$GF_PATHS_PLUGINS"

export GF_SERVER_HTTP_PORT="${PORT:-3000}"
exec su -s /bin/sh -m grafana -c /run.sh
