#!/bin/bash
set -euxo pipefail

dnf install -y docker
systemctl enable --now docker
curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 \
  -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

mkdir -p /opt/observability
cat > /opt/observability/prometheus.yml <<EOF
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: "ecs-nginx"
    ec2_sd_configs: []
    static_configs:
      - targets: ["nginx-exporter.internal:9113"]

  - job_name: "rds-mariadb"
    static_configs:
      - targets: ["mysqld-exporter.internal:9187"]

  # Vervang bovenstaande static targets door de AWS EC2/ECS service discovery
  # (ec2_sd_config / ecs_sd_config) zodra taken/instances dynamisch schalen,
  # zodat nieuwe Fargate-taken automatisch worden meegenomen.
EOF

cat > /opt/observability/docker-compose.yml <<EOF
version: "3.8"
services:
  prometheus:
    image: prom/prometheus:latest
    restart: unless-stopped
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus-data:/prometheus
    ports:
      - "9090:9090"

  grafana:
    image: grafana/grafana:latest
    restart: unless-stopped
    depends_on:
      - prometheus
    environment:
      # Wijzig dit direct na de eerste login; overweeg dit op termijn uit
      # AWS Secrets Manager te halen in plaats van hier hardcoded te zetten.
      - GF_SECURITY_ADMIN_PASSWORD=changeme-rotate-me
    volumes:
      - grafana-data:/var/lib/grafana
    ports:
      - "3000:3000"

volumes:
  prometheus-data:
  grafana-data:
EOF

cd /opt/observability
/usr/local/bin/docker-compose up -d
