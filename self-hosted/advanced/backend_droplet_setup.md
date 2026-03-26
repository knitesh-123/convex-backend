# Backend Droplet Setup

These are the current instructions for setting up the Convex backend droplet.
They assume:

- you are using the repo's `observability` branch
- Caddy will terminate TLS on the backend droplet
- the Convex dashboard is not part of this setup
- the backend stores durable state in managed SQL plus Cloudflare R2
- the observability droplet is separate and will scrape the backend droplet's
  metrics adapter on port `9464`

## What This Host Runs

The backend droplet runs:

- Convex backend
- metrics adapter
- Caddy

It does not run:

- Grafana
- VictoriaMetrics
- Convex dashboard

## Files Used

- `self-hosted/docker/docker-compose.backend-droplet.yml`
- `self-hosted/docker/.env.backend.example`
- `self-hosted/docker/setup_backend_droplet.sh`

## Before You Start

- Create your managed SQL database first
- Create your Cloudflare R2 buckets first
- Decide your stable `INSTANCE_NAME` and `INSTANCE_SECRET`
- Point DNS for your two public hostnames at the backend droplet

Use the same `INSTANCE_NAME` and `INSTANCE_SECRET` everywhere for this
deployment.

Set exactly one of:

- `POSTGRES_URL`
- `MYSQL_URL`

## Clone The Repo

```sh
git clone -b observability https://github.com/get-convex/convex-backend.git
cd convex-backend
```

## Create The Backend Env File

```sh
cp self-hosted/docker/.env.backend.example self-hosted/docker/.env.backend
```

Then edit `self-hosted/docker/.env.backend`.

## Required Env Vars

Fill in at least:

- `INSTANCE_NAME`
- `INSTANCE_SECRET`
- one of `POSTGRES_URL` or `MYSQL_URL`
- `CONVEX_CLOUD_ORIGIN`
- `CONVEX_SITE_ORIGIN`
- `CADDY_EMAIL`
- `AWS_REGION`
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `S3_ENDPOINT_URL`
- `S3_STORAGE_EXPORTS_BUCKET`
- `S3_STORAGE_SNAPSHOT_IMPORTS_BUCKET`
- `S3_STORAGE_MODULES_BUCKET`
- `S3_STORAGE_FILES_BUCKET`
- `S3_STORAGE_SEARCH_BUCKET`

For Cloudflare R2, use:

```dotenv
AWS_REGION=auto
S3_ENDPOINT_URL=https://<account-id>.r2.cloudflarestorage.com
```

## Public Hostnames

Caddy uses these two env vars to decide which domains to serve:

- `CONVEX_CLOUD_ORIGIN`
- `CONVEX_SITE_ORIGIN`

Example:

```dotenv
CONVEX_CLOUD_ORIGIN=https://convex-api.example.com
CONVEX_SITE_ORIGIN=https://convex-site.example.com
```

That produces this routing:

- `convex-api.example.com` -> local backend on `127.0.0.1:3210`
- `convex-site.example.com` -> local site proxy on `127.0.0.1:3211`

## Run The Setup Script

```sh
sudo bash self-hosted/docker/setup_backend_droplet.sh
```

The script will:

- install Docker and Docker Compose if needed
- install Caddy if needed
- run `ufw allow 80/tcp` and `ufw allow 443/tcp` if `ufw` is installed
- write `/etc/caddy/Caddyfile`
- start Caddy
- start the backend and metrics adapter containers
- verify local health endpoints
- print the generated Convex admin key

## What The Script Starts

The backend stack uses:

- `self-hosted/docker/docker-compose.backend-droplet.yml`

Containers:

- `backend`
- `metricsadapter`

Bindings:

- backend API on `127.0.0.1:3210`
- site proxy on `127.0.0.1:3211`
- metrics adapter on `${METRICS_ADAPTER_BIND_IP:-0.0.0.0}:9464`

## Verify The Backend Droplet

Run:

```sh
curl -f http://127.0.0.1:3210/version
curl -f http://127.0.0.1:9464/health
```

Then verify the public URLs in the browser or with `curl`:

```sh
curl -I https://convex-api.example.com/version
curl -I https://convex-site.example.com/
```

## Start Manually Without The Script

If Docker and Caddy are already set up, you can start only the containers with:

```sh
docker compose \
  --env-file self-hosted/docker/.env.backend \
  -f self-hosted/docker/docker-compose.backend-droplet.yml \
  up -d
```

## Generate The Admin Key Again

```sh
docker compose \
  --env-file self-hosted/docker/.env.backend \
  -f self-hosted/docker/docker-compose.backend-droplet.yml \
  exec -T backend sh -lc './generate_key "$INSTANCE_NAME" "$INSTANCE_SECRET"'
```

## Shutdown

```sh
docker compose \
  --env-file self-hosted/docker/.env.backend \
  -f self-hosted/docker/docker-compose.backend-droplet.yml \
  down
```

## Firewall Recommendation

Allow:

- `22/tcp` from your IP
- `80/tcp` from the internet
- `443/tcp` from the internet
- `9464/tcp` only from the observability droplet over private networking

Do not expose publicly:

- `3210/tcp`
- `3211/tcp`

Those stay behind Caddy on localhost.

## Notes

- No custom backend image build is required for this setup; it uses the
  published Convex backend image.
- Run only one active Convex backend at a time for a given deployment.
- If you move the deployment to another machine, reuse the same:
  - `INSTANCE_NAME`
  - `INSTANCE_SECRET`
  - SQL URL
  - R2 configuration
