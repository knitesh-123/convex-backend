# Railway Observability Setup

These instructions replace the observability droplet with Railway while keeping
the Convex backend on a DigitalOcean droplet.

The resulting layout is:

- Backend host: DigitalOcean droplet running Convex backend, metrics adapter,
  and Caddy
- Observability host: Railway running VictoriaMetrics and Grafana
- Durable state: managed SQL plus Cloudflare R2

## Required Change On The Backend Droplet

Railway cannot scrape the backend droplet over private DigitalOcean networking,
so the backend droplet must expose a protected public metrics URL.

We do that by making Caddy expose the metrics adapter on the API hostname under
a dedicated path.

Add these to `self-hosted/docker/.env.backend` on the backend droplet:

```dotenv
METRICS_PUBLIC_PATH=/_metrics
METRICS_BASIC_AUTH_USERNAME=metrics
METRICS_BASIC_AUTH_PASSWORD=replace-with-a-strong-password
```

Then rerun:

```sh
sudo bash self-hosted/docker/setup_backend_droplet.sh
```

This creates a protected public metrics endpoint at:

```text
https://<api-hostname>/_metrics
```

Example:

```text
https://convex-api.pebblelabs.io/_metrics
```

## Railway Services

Create two Railway services from the same repo/branch:

- `victoriametrics`
- `grafana`

Use the repo's `observability` branch.

## VictoriaMetrics Service On Railway

For the Railway service:

- keep the repo root as the build context
- leave the root directory unset
- set the Dockerfile path to:

```text
self-hosted/railway/observability/victoriametrics/Dockerfile
```

Attach a persistent volume mounted at:

```text
/victoria-metrics-data
```

Set these env vars:

```dotenv
BACKEND_METRICS_HOST=convex-api.pebblelabs.io
BACKEND_METRICS_SCHEME=https
BACKEND_METRICS_PATH=/_metrics
BACKEND_METRICS_USERNAME=metrics
BACKEND_METRICS_PASSWORD=replace-with-the-same-password-as-the-droplet
SCRAPE_INTERVAL=15s
```

Notes:

- `BACKEND_METRICS_HOST` should be just the host, not a full URL
- `BACKEND_METRICS_PATH` should match `METRICS_PUBLIC_PATH` on the backend
- the username and password must match the backend droplet values

## Grafana Service On Railway

For the Railway service:

- keep the repo root as the build context
- leave the root directory unset
- set the Dockerfile path to:

```text
self-hosted/railway/observability/grafana/Dockerfile
```

Attach a persistent volume mounted at:

```text
/data
```

Set these env vars:

```dotenv
GF_SECURITY_ADMIN_USER=admin
GF_SECURITY_ADMIN_PASSWORD=replace-with-a-strong-password
GF_USERS_ALLOW_SIGN_UP=false
VICTORIAMETRICS_URL=http://<victoriametrics-internal-or-public-url>
GF_PATHS_DATA=/data
GF_PATHS_LOGS=/data/logs
GF_PATHS_PLUGINS=/data/plugins
```

Prefer using a Railway internal/private URL for `VICTORIAMETRICS_URL` if your
Railway setup supports it. If not, you can temporarily use the VictoriaMetrics
service's public Railway URL.

## Verify The Setup

From VictoriaMetrics, the query:

```text
up
```

should show the `convex` job at `1`.

From Grafana:

- log in
- open `Convex Server Overview`
- verify charts are receiving data

## What Changed Compared To The DigitalOcean Observability Droplet

- No private-IP scrape from VictoriaMetrics to the backend droplet
- VictoriaMetrics now scrapes the droplet over public HTTPS
- The backend droplet needs a protected public metrics path
- Grafana and VictoriaMetrics move from Docker Compose on a droplet to two
  Railway services
