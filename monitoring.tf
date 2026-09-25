# ============================================================
# Monitoring, Observability & Auto-Scaling (REQ-NCA-P1-05)
#
# LET OP - bewuste afwijking van het ontwerp: deze instance staat in de publieke
# Hub-subnet (met een eigen public IP), niet in de afgeschermde Mgmt-subnet.
# Reden: het ontwerp plaatst Grafana achter "Bastion/VPN-beheer", maar een echte
# Client VPN opzetten (certificaten, endpoint, routing) is een apart, groot project
# op zich. Toegang is beperkt tot var.admin_cidr, dus zet die naar jouw eigen IP.
# ============================================================

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

resource "random_password" "grafana_admin" {
  length  = 16
  special = false
}

resource "aws_iam_role" "monitoring" {
  name = "monitoring-ec2-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "monitoring_cloudwatch" {
  role       = aws_iam_role.monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess"
}

resource "aws_iam_instance_profile" "monitoring" {
  name = "monitoring-ec2-profile"
  role = aws_iam_role.monitoring.name
}

locals {
  monitoring_user_data = <<-EOF
    #!/bin/bash
    set -e
    dnf install -y docker
    systemctl enable --now docker
    curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose

    mkdir -p /opt/monitoring/grafana/provisioning/datasources

    cat > /opt/monitoring/prometheus.yml <<'PROM'
    global:
      scrape_interval: 15s
    scrape_configs:
      - job_name: 'prometheus'
        static_configs:
          - targets: ['localhost:9090']
      - job_name: 'nginx-web'
        dns_sd_configs:
          - names: ['web.internal.local']
            type: 'A'
            port: 9113
    PROM

    cat > /opt/monitoring/grafana/provisioning/datasources/datasources.yml <<'DS'
    apiVersion: 1
    datasources:
      - name: Prometheus
        type: prometheus
        access: proxy
        url: http://prometheus:9090
        isDefault: true
      - name: CloudWatch
        type: cloudwatch
        jsonData:
          authType: default
          defaultRegion: ${var.aws_region}
    DS

    cat > /opt/monitoring/docker-compose.yml <<'DC'
    version: "3.8"
    services:
      prometheus:
        image: prom/prometheus:latest
        restart: unless-stopped
        volumes:
          - /opt/monitoring/prometheus.yml:/etc/prometheus/prometheus.yml
        ports:
          - "9090:9090"
      grafana:
        image: grafana/grafana:latest
        restart: unless-stopped
        environment:
          - GF_SECURITY_ADMIN_PASSWORD=${random_password.grafana_admin.result}
        volumes:
          - /opt/monitoring/grafana/provisioning:/etc/grafana/provisioning
        ports:
          - "3000:3000"
    DC

    cd /opt/monitoring && /usr/local/bin/docker-compose up -d
  EOF
}

resource "aws_instance" "monitoring" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.hub_public_a.id
  vpc_security_group_ids      = [aws_security_group.mgmt_sg.id]
  iam_instance_profile        = aws_iam_instance_profile.monitoring.name
  key_name                    = var.key_pair_name != "" ? var.key_pair_name : null
  associate_public_ip_address = true
  user_data                   = local.monitoring_user_data

  tags = { Name = "monitoring-prometheus-grafana" }
}
