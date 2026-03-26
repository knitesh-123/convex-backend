FROM grafana/grafana:latest

USER root

COPY self-hosted/railway/observability/grafana/entrypoint.sh /entrypoint.sh
COPY self-hosted/docker/observability/grafana/provisioning/dashboards /etc/grafana/provisioning/dashboards
COPY self-hosted/docker/observability/grafana/dashboards /var/lib/grafana/dashboards

RUN chmod +x /entrypoint.sh && \
    mkdir -p /etc/grafana/provisioning/datasources && \
    chown -R 472:0 /entrypoint.sh /etc/grafana/provisioning /var/lib/grafana/dashboards

ENTRYPOINT ["/entrypoint.sh"]
