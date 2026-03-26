# Convex Server Observability

This is our working reference for observing a self-hosted Convex backend without
making Convex code changes.

Scope:

- Focus on the Convex server only
- Ignore Postgres internals
- No Convex source changes
- Treat this document as the baseline and update it whenever we change our
  deployment, logging, scraping, or debugging approach

## Goals

We want the best possible visibility into:

- HTTP request latency inside the Convex server
- WebSocket and reactive query latency
- Per-function latency, cache behavior, and concurrency
- Request-by-request execution details from Convex itself

We do not get a built-in full internal waterfall for every request without code
changes, but we can get very close by combining Convex metrics, Convex
execution streams, and the self-hosted dashboard.

## Concrete Plan

1. Run the backend in observability mode
2. Scrape Convex's built-in `/metrics` endpoint with VictoriaMetrics
3. Use Grafana for server-wide latency dashboards
4. Use the self-hosted Convex dashboard for per-function metrics and live logs
5. Collect `stream_udf_execution` / `stream_function_logs` for request-by-request
   drill-down
6. Keep a short-lived incident mode for deeper cache and subscription insight

## Backend Runtime Settings

Use these as the default backend settings:

```yaml
environment:
  LOG_FORMAT: json
  RUST_LOG: info
```

Notes:

- `LOG_FORMAT=json` makes backend service logs machine-parsable.
- Start with `RUST_LOG=info`; only raise specific modules when debugging.
- If we build our own image, prefer `--build-arg debug=1` so the binary is not
  stripped. That helps `perf` and eBPF tooling later.

## Starter Compose Stack

This repo now includes an observability overlay compose file at
`self-hosted/docker/docker-compose.observability.yml`.

It does three things:

- switches the backend service to our local debug-friendly image
- enables Convex `/metrics`
- adds a small metrics adapter, VictoriaMetrics, and Grafana

The canonical env file for this stack is:

- `self-hosted/docker/.env.observability`

An example copy is committed at:

- `self-hosted/docker/.env.observability.example`

Run it with:

```sh
docker compose \
  --env-file self-hosted/docker/.env.observability \
  -f self-hosted/docker/docker-compose.yml \
  -f self-hosted/docker/docker-compose.observability.yml \
  up -d
```

Default ports:

- Convex backend: `3210`
- Convex site proxy / HTTP actions: `3211`
- Convex dashboard: `6791`
- VictoriaMetrics: `8428`
- Grafana: `3000`

Default Grafana login:

- username: `admin`
- password: `admin`

Edit `self-hosted/docker/.env.observability` to change any of the following:

- `OBSERVABILITY_BACKEND_IMAGE`
- `PORT`
- `SITE_PROXY_PORT`
- `DASHBOARD_PORT`
- `VICTORIAMETRICS_PORT`
- `GRAFANA_PORT`
- `DISABLE_METRICS_ENDPOINT`
- `LOG_FORMAT`
- `RUST_LOG`
- `GRAFANA_ADMIN_USER`
- `GRAFANA_ADMIN_PASSWORD`

## DigitalOcean Split Deployment

For a production-ish setup where the Convex server stays disposable, use two
hosts:

- Backend droplet: Convex backend, Convex dashboard, and `metricsadapter`
- Observability droplet: VictoriaMetrics and Grafana
- External services: SQL database and S3-compatible object storage such as R2

Important rules:

- Use the same `INSTANCE_NAME` and `INSTANCE_SECRET` everywhere for the same
  deployment.
- Use a fresh database when creating a brand-new deployment.
- Run only one active Convex backend for a deployment at a time.
- If using PlanetScale, set `MYSQL_URL`, not `POSTGRES_URL`.

### Files To Use

Backend droplet:

- `self-hosted/docker/docker-compose.yml`
- `self-hosted/docker/docker-compose.backend-observability.yml`
- `self-hosted/docker/.env.backend.example`

Observability droplet:

- `self-hosted/docker/docker-compose.observability-remote.yml`
- `self-hosted/docker/.env.observability-remote.example`
- `self-hosted/docker/observability/victoriametrics/promscrape.remote.yml`

### Backend Droplet Setup

1. Clone the repo:

```sh
git clone https://github.com/get-convex/convex-backend.git
cd convex-backend
```

2. Create the backend env file:

```sh
cp self-hosted/docker/.env.backend.example self-hosted/docker/.env.backend
```

3. Edit `self-hosted/docker/.env.backend` and fill in:

- `INSTANCE_NAME`
- `INSTANCE_SECRET`
- exactly one of `MYSQL_URL` or `POSTGRES_URL`
- all R2 bucket variables
- `CONVEX_CLOUD_ORIGIN`
- `CONVEX_SITE_ORIGIN`
- `NEXT_PUBLIC_DEPLOYMENT_URL`

4. Start the backend stack:

```sh
docker compose \
  --env-file self-hosted/docker/.env.backend \
  -f self-hosted/docker/docker-compose.yml \
  -f self-hosted/docker/docker-compose.backend-observability.yml \
  up -d
```

5. Generate the admin key from the running backend image:

```sh
docker compose \
  --env-file self-hosted/docker/.env.backend \
  -f self-hosted/docker/docker-compose.yml \
  -f self-hosted/docker/docker-compose.backend-observability.yml \
  exec backend sh -lc './generate_key "$INSTANCE_NAME" "$INSTANCE_SECRET"'
```

6. Verify the backend and metrics adapter:

```sh
curl -f http://127.0.0.1:3210/version
curl -f http://127.0.0.1:9464/health
curl -f http://127.0.0.1:6791
```

### Observability Droplet Setup

1. Clone the repo:

```sh
git clone https://github.com/get-convex/convex-backend.git
cd convex-backend
```

2. Create the observability env file:

```sh
cp self-hosted/docker/.env.observability-remote.example self-hosted/docker/.env.observability-remote
```

3. Edit `self-hosted/docker/.env.observability-remote` and set Grafana
credentials.

4. Edit `self-hosted/docker/observability/victoriametrics/promscrape.remote.yml`
and replace `10.0.0.10:9464` with the backend droplet's private IP or private
DNS name.

5. Start VictoriaMetrics and Grafana:

```sh
docker compose \
  --env-file self-hosted/docker/.env.observability-remote \
  -f self-hosted/docker/docker-compose.observability-remote.yml \
  up -d
```

6. Verify observability:

```sh
curl -f http://127.0.0.1:8428/health
curl -f http://127.0.0.1:3000/api/health
curl -s 'http://127.0.0.1:8428/api/v1/query?query=up'
```

### Migration / Rollout Order

If you are moving from another self-hosted instance:

1. Start the new backend droplet with fresh SQL + R2 configuration
2. Deploy code with `npx convex deploy`
3. Import data with `npx convex import --replace-all <backup.zip>`
4. Verify the app on the new backend
5. Shut down the old backend
6. Start any alternate backend location only after the old one is stopped

### Shutdown Commands

Backend droplet:

```sh
docker compose \
  --env-file self-hosted/docker/.env.backend \
  -f self-hosted/docker/docker-compose.yml \
  -f self-hosted/docker/docker-compose.backend-observability.yml \
  down
```

Observability droplet:

```sh
docker compose \
  --env-file self-hosted/docker/.env.observability-remote \
  -f self-hosted/docker/docker-compose.observability-remote.yml \
  down
```

### Recommended Firewall Rules

Backend droplet:

- allow `22/tcp` from your IP
- allow `3210/tcp` and `3211/tcp` from wherever your app or reverse proxy needs
  them
- allow `6791/tcp` only from your IP or VPN
- allow `9464/tcp` only from the observability droplet over private networking

Observability droplet:

- allow `22/tcp` from your IP
- allow `3000/tcp` only from your IP or VPN
- do not expose `8428/tcp` publicly unless you have a specific need

## Required Services

Keep these running alongside the Convex backend:

- A metrics adapter that strips invalid `vmhistogram` metadata from Convex's
  `/metrics` output
- VictoriaMetrics scraping Convex `/metrics`
- Grafana for dashboards and alerting
- The self-hosted Convex dashboard for per-function metrics and live logs
- Optional log storage such as Loki or ELK for backend JSON logs

The self-hosted flow for generating the admin key and opening the dashboard is
documented in `self-hosted/README.md`.

## VictoriaMetrics Scrape Config

Minimal scrape job:

```yaml
scrape_configs:
  - job_name: convex
    metrics_path: /metrics
    scrape_interval: 15s
    static_configs:
      - targets: ["metricsadapter:9464"]
```

Convex exposes `/metrics` by default unless `DISABLE_METRICS_ENDPOINT=true`.

Note:

- Convex exports `vmhistogram` metadata lines, which are rejected by both stock
  Prometheus and VictoriaMetrics scrape parsing.
- The `metricsadapter` sidecar strips only the invalid `# TYPE ... vmhistogram`
  lines and leaves the metric samples intact.
- Grafana still uses the Prometheus datasource type against VictoriaMetrics' API.

## What To Watch In Grafana

### HTTP

- `http_handle_duration_seconds`
  - Total time spent handling HTTP requests inside Convex
  - Group by `endpoint`, `method`, and `status`

Recommended query:

```promql
histogram_quantile(
  0.95,
  sum by (vmrange, endpoint, method, status) (
    rate(http_handle_duration_seconds_bucket[5m])
  )
)
```

### WebSocket / Sync Transport

- `backend_ws_upgrade_seconds`
  - WebSocket upgrade latency
- `backend_ping_pong_seconds`
  - Approximate WebSocket round-trip time
- `backend_ws_send_delay_seconds`
  - Delay between generating a sync message and actually sending it
- `sync_protocol_websockets_total`
  - Number of active WebSocket connections

Recommended queries:

```promql
histogram_quantile(
  0.95,
  sum by (vmrange, endpoint) (
    rate(backend_ws_send_delay_seconds_bucket[5m])
  )
)

sum(sync_protocol_websockets_total)
```

### Reactive Query Pipeline

- `sync_update_queries_seconds`
  - Time spent refreshing and rerunning reactive queries
- `modify_query_to_transition_seconds`
  - Time from `ModifyQuerySet` to sending the transition back to the client
- `sync_process_client_message_seconds`
  - Delay between receiving a WebSocket client message and processing it
- `sync_mutation_queue_seconds`
  - Queueing delay for mutations inside the single-threaded sync worker
- `sync_query_invalidation_lag_seconds`
  - Time from invalidating write to query rerun
- `sync_worker_query_retry_total`
  - Query retries in the sync worker
- `sync_query_result_dedup_total`
  - Count of query reruns that produced the same value and were deduped

Recommended queries:

```promql
histogram_quantile(
  0.95,
  sum by (vmrange, partition_id) (
    rate(sync_update_queries_seconds_bucket[5m])
  )
)

histogram_quantile(
  0.95,
  sum by (vmrange, partition_id) (
    rate(modify_query_to_transition_seconds_bucket[5m])
  )
)

histogram_quantile(
  0.95,
  sum by (vmrange, partition_id) (
    rate(sync_query_invalidation_lag_seconds_bucket[5m])
  )
)

rate(sync_worker_query_retry_total[5m])
```

### Payload / Message Size

- `ws_client_message_bytes`
- `sync_transition_message_size_bytes`

Use these to catch large request payloads and oversized reactive transitions.

## Use The Convex Dashboard For Per-Function Insight

The dashboard is the easiest no-code way to inspect function-level behavior.

Use the dashboard views backed by these routes under `/api/app_metrics/*`:

- `latency_percentiles`
- `cache_hit_percentage`
- `cache_hit_percentage_top_k`
- `udf_rate`
- `function_call_count_top_k`
- `function_concurrency`
- `scheduled_job_lag`
- `table_rate`

These are the best built-in sources for answering:

- Which function is slow?
- Is the slowness caused by cache misses?
- Is concurrency or queueing rising?
- Is reactive invalidation lag growing?

## Collect Execution Streams For Request-Level Drill-Down

For deeper analysis, use these backend endpoints:

- `/api/stream_udf_execution`
- `/api/stream_function_logs`

These streams are the highest-signal no-code source for "what happened inside
Convex for this request?"

Key fields available in function completion events:

- `request_id`
- `execution_id`
- `parent_execution_id`
- `identifier`
- `udf_type`
- `execution_time`
- `user_execution_time`
- `cached_result`
- `usage_stats`
- `occ_info.retry_count`

Use them to reconstruct execution trees such as:

- root action -> child query -> child mutation
- root HTTP request -> function execution -> nested internal call

Operational notes:

- These are long-poll endpoints, not WebSockets.
- They return after up to 60 seconds even when idle, so they are easy to poll
  from an external collector.
- The dashboard and CLI already rely on these surfaces.

## Incident Mode

Use this only temporarily during active debugging:

```yaml
environment:
  LOG_FORMAT: json
  RUST_LOG: info,application::cache=debug
  SUBSCRIPTION_PROCESS_LOG_ENTRY_TRACING_THRESHOLD: "0"
  SUBSCRIPTION_ADVANCE_LOG_TRACING_THRESHOLD: "0"
```

What this adds:

- Cache hit/wait/execute decisions from `application::cache`
- Much more logging around subscription invalidation and advancement

Only enable these settings for short periods because they are noisier and may
increase overhead.

## Optional Escalations

These still avoid Convex code changes:

- Build with `--build-arg debug=1` to keep symbols for `perf` or eBPF profiling
- Use host-level `perf`, `bpftrace`, Parca, or Pyroscope eBPF when CPU time is
  unclear from metrics alone
- Send backend stdout/stderr JSON logs to Loki or ELK for search and retention

## What This Setup Can Answer Well

- Is the backend HTTP handler slow?
- Is WebSocket send delay increasing?
- Are reactive query refreshes slow?
- Are transitions large?
- Which UDFs are slow?
- Which UDFs are missing cache most often?
- Are queueing and concurrency rising?
- Which request IDs had slow executions, retries, or nested calls?

## What This Setup Still Cannot Fully Show

Without changing Convex source, we still do not get a fully stitched internal
waterfall that breaks a single request into every internal phase, such as:

- auth
- cache lookup
- in-memory index hit vs snapshot-cache hit
- invalidation processing
- exact sync-worker sub-steps
- final server-to-client push as one joined timeline

We can infer most of that behavior from metrics and execution streams, but it is
still manual.

## Default Operating Procedure

When something is slow:

1. Check Grafana for `http_handle_duration_seconds`
2. Check sync and WebSocket panels for `sync_update_queries_seconds`,
   `modify_query_to_transition_seconds`, and `backend_ws_send_delay_seconds`
3. Open the Convex dashboard and inspect per-function latency percentiles and
   cache hit percentage
4. Pull execution events from `stream_udf_execution` for the affected time range
5. If the issue is still unclear, temporarily enable incident mode

## Maintenance Rule

Whenever we change any of the following, update this document:

- backend runtime env vars
- VictoriaMetrics scrape settings
- Grafana dashboards or alert thresholds
- log collection approach
- incident-mode settings
- request-level collection workflow
