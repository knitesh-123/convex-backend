#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="${1:-$SCRIPT_DIR/.env.backend}"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.backend-droplet.yml"
CADDYFILE_PATH="/etc/caddy/Caddyfile"

if [[ ! -f "$ENV_FILE" ]]; then
  cp "$SCRIPT_DIR/.env.backend.example" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  printf "Created %s from example. Fill it in and rerun.\n" "$ENV_FILE" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

if [[ ${EUID} -eq 0 ]]; then
  SUDO=""
else
  if ! command -v sudo >/dev/null 2>&1; then
    printf "sudo is required when not running as root.\n" >&2
    exit 1
  fi
  SUDO="sudo"
fi

require_var() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    printf "Missing required variable: %s\n" "$name" >&2
    exit 1
  fi
}

url_host() {
  local value="$1"
  value="${value#http://}"
  value="${value#https://}"
  printf "%s\n" "${value%%/*}"
}

install_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    return
  fi

  $SUDO apt-get update
  $SUDO apt-get install -y ca-certificates curl gnupg
  $SUDO install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | $SUDO gpg --dearmor -o /etc/apt/keyrings/docker.asc
    $SUDO chmod a+r /etc/apt/keyrings/docker.asc
  fi
  if [[ ! -f /etc/apt/sources.list.d/docker.list ]]; then
    printf "deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu %s stable\n" \
      "$(dpkg --print-architecture)" \
      "$(. /etc/os-release && printf "%s" "$VERSION_CODENAME")" | \
      $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null
  fi
  $SUDO apt-get update
  $SUDO apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  $SUDO systemctl enable --now docker
}

install_caddy() {
  if command -v caddy >/dev/null 2>&1; then
    $SUDO systemctl enable --now caddy
    return
  fi

  $SUDO apt-get update
  $SUDO apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gpg
  if [[ ! -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg ]]; then
    curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key | \
      $SUDO gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  fi
  if [[ ! -f /etc/apt/sources.list.d/caddy-stable.list ]]; then
    curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt | \
      $SUDO tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
  fi
  $SUDO apt-get update
  $SUDO apt-get install -y caddy
  $SUDO systemctl enable --now caddy
}

validate_config() {
  require_var INSTANCE_NAME
  require_var INSTANCE_SECRET
  require_var CONVEX_CLOUD_ORIGIN
  require_var CONVEX_SITE_ORIGIN
  require_var CADDY_EMAIL
  require_var AWS_REGION
  require_var AWS_ACCESS_KEY_ID
  require_var AWS_SECRET_ACCESS_KEY
  require_var S3_ENDPOINT_URL
  require_var S3_STORAGE_EXPORTS_BUCKET
  require_var S3_STORAGE_SNAPSHOT_IMPORTS_BUCKET
  require_var S3_STORAGE_MODULES_BUCKET
  require_var S3_STORAGE_FILES_BUCKET
  require_var S3_STORAGE_SEARCH_BUCKET

  if [[ -n "${POSTGRES_URL:-}" && -n "${MYSQL_URL:-}" ]]; then
    printf "Set only one of POSTGRES_URL or MYSQL_URL.\n" >&2
    exit 1
  fi
  if [[ -z "${POSTGRES_URL:-}" && -z "${MYSQL_URL:-}" ]]; then
    printf "Set one of POSTGRES_URL or MYSQL_URL.\n" >&2
    exit 1
  fi

  case "$CONVEX_CLOUD_ORIGIN" in
    https://*) ;;
    *) printf "CONVEX_CLOUD_ORIGIN must start with https:// for Caddy-managed TLS.\n" >&2; exit 1 ;;
  esac
  case "$CONVEX_SITE_ORIGIN" in
    https://*) ;;
    *) printf "CONVEX_SITE_ORIGIN must start with https:// for Caddy-managed TLS.\n" >&2; exit 1 ;;
  esac
}

write_caddyfile() {
  local api_host site_host temp_file
  api_host="$(url_host "$CONVEX_CLOUD_ORIGIN")"
  site_host="$(url_host "$CONVEX_SITE_ORIGIN")"
  temp_file="$(mktemp)"

  cat >"$temp_file" <<EOF
{
    email ${CADDY_EMAIL}
}

${api_host} {
    reverse_proxy 127.0.0.1:${PORT:-3210}
}

${site_host} {
    reverse_proxy 127.0.0.1:${SITE_PROXY_PORT:-3211}
}
EOF

  $SUDO mkdir -p /etc/caddy
  $SUDO mv "$temp_file" "$CADDYFILE_PATH"
  $SUDO chown root:caddy "$CADDYFILE_PATH"
  $SUDO chmod 640 "$CADDYFILE_PATH"
  $SUDO caddy validate --config "$CADDYFILE_PATH"
  $SUDO systemctl reload caddy
}

start_backend() {
  docker compose \
    --env-file "$ENV_FILE" \
    -f "$COMPOSE_FILE" \
    up -d
}

wait_for_url() {
  local url="$1"
  local label="$2"
  local attempt
  for attempt in $(seq 1 60); do
    if curl -fsS "$url" >/dev/null; then
      return 0
    fi
    sleep 2
  done
  printf "Timed out waiting for %s at %s\n" "$label" "$url" >&2
  exit 1
}

generate_admin_key() {
  docker compose \
    --env-file "$ENV_FILE" \
    -f "$COMPOSE_FILE" \
    exec -T backend sh -lc './generate_key "$INSTANCE_NAME" "$INSTANCE_SECRET"' | tail -n 1
}

verify_services() {
  wait_for_url "http://127.0.0.1:${PORT:-3210}/version" "Convex backend"
  wait_for_url "http://127.0.0.1:${METRICS_ADAPTER_PORT:-9464}/health" "metrics adapter"
}

main() {
  validate_config
  install_docker
  install_caddy
  write_caddyfile
  start_backend
  verify_services

  local admin_key
  admin_key="$(generate_admin_key)"

  printf "Backend droplet setup complete.\n"
  printf "API: %s\n" "$CONVEX_CLOUD_ORIGIN"
  printf "Site: %s\n" "$CONVEX_SITE_ORIGIN"
  printf "Metrics adapter: http://%s:%s/metrics\n" "${METRICS_ADAPTER_BIND_IP:-0.0.0.0}" "${METRICS_ADAPTER_PORT:-9464}"
  printf "Admin key: %s\n" "$admin_key"
}

main "$@"
