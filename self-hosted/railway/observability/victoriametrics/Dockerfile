FROM victoriametrics/victoria-metrics:latest AS vm

FROM alpine:3.20

RUN apk add --no-cache ca-certificates

COPY --from=vm /victoria-metrics-prod /victoria-metrics-prod
COPY self-hosted/railway/observability/victoriametrics/entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh && mkdir -p /etc/victoriametrics /victoria-metrics-data

ENTRYPOINT ["/entrypoint.sh"]
