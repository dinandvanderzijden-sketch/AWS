# ============================================================
# Monitoring, Observability & Auto-Scaling (REQ-NCA-P1-05)
#
# AFWIJKING VAN HET ONTWERPDOCUMENT (bewust, gedocumenteerd)
# Deze instance staat in de publieke Hub-subnet (met een eigen public IP),
# niet in de afgeschermde Mgmt-subnet. Een echte Client VPN of Bastion Host
# is een apart groot project (certificaten, endpoint, routing, fail-over).
#
# Wat we daarom DOEN om REQ-NCA-P1-02 te respecteren:
#   - de security group is fail-closed: zonder var.admin_cidr is er geen enkele
#     ingress-regel en is de instance vanaf het internet dicht (zie security.tf)
#   - var.admin_cidr weigert 0.0.0.0/0 (validation in variables.tf)
#   - SSH is optioneel; voor beheer is er een IAM-profiel voor SSM Session
#     Manager, zodat poort 22 helemaal niet open hoeft te staan
# ============================================================

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

data "aws_caller_identity" "current" {}

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

# REQ-NCA-P1-02: beheer loopt via SSM Session Manager in plaats van via een
# open SSH-poort. Alleen het beheer-VPC-ID nodig, geen open poorten.
#
# Deze policy staat als locals + jsonencode, niet als
# data "aws_iam_policy_document": zo is ze tijdens 'terraform test' als echte
# waarde te controleren, zonder AWS-account of live data-bron.
locals {
  monitoring_ssm_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SessionManagerWithoutIngressPort"
        Effect = "Allow"
        Action = [
          "ssm:UpdateInstanceInformation",
          "ssm:StartSession",
          "ssm:TerminateSession",
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel",
        ]
        Resource = "*"
      },
      {
        Sid    = "ShellOutputForTroubleshooting"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams",
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/ec2/monitoring-prometheus-grafana*"
      },
    ]
  })
}

resource "aws_iam_role_policy" "monitoring_ssm" {
  name   = "monitoring-ssm-session-manager"
  role   = aws_iam_role.monitoring.name
  policy = local.monitoring_ssm_json
}

resource "aws_iam_instance_profile" "monitoring" {
  name = "monitoring-ec2-profile"
  role = aws_iam_role.monitoring.name
}

# ============================================================
# Grafana-dashboard
#
# REQ-NCA-P1-05 acceptatiecriterium 1: "Een actief dashboard toont realtime
# status van de infrastructuur en applicaties."
#
# Het dashboard wordt hier in Terraform gegenereerd (niet als los JSON-bestand)
# zodat cluster-, service-, loadbalancer- en database-namen nooit uit sync
# kunnen lopen met de werkelijke resources. Die namen stonden eerder
# hardcoded in de workflow en in task-definition.json - een echte bron van
# drift (REQ-NCA-P1-08).
#
# De panels gebruiken de CloudWatch-datasource, NIET Prometheus. Reden:
# Container Insights staat aan op de ECS-cluster, dus deze metrieken zijn
# gegarandeerd beschikbaar. De nginx_status-metrieken uit Prometheus blijven
# als bonus-paneel staan; die zijn afhankelijk van cross-VPC DNS en kunnen dus
# leeg zijn (zie TESTPLAN.md, test T4).
#
# De drempelwaarden zijn identiek aan de tabel "Onderbouwing Monitorde
# Metrieken & Drempeloverschrijdingen" uit het ontwerpdocument.
# ============================================================

locals {
  cw_uid       = "cloudwatch"
  prom_uid     = "prometheus"
  cluster_name = aws_ecs_cluster.main.name
  service_name = aws_ecs_service.web.name

  # arn_suffix = "app/hub-alb/<id>", precies wat de CloudWatch-dimensie
  # 'LoadBalancer' verwacht. Met de korte naam ("hub-alb") levert de
  # datasource nul datapoints op - dus hier bewust de suffix.
  alb_dim = aws_lb.external_alb.arn_suffix
  rds_dim = aws_db_instance.mariadb.identifier

  # De zes panelen, in de volgorde van de tabel uit het ontwerpdocument.
  # 'threshold = null' betekent: alleen tonen, geen alarm.
  panels = [
    {
      title     = "ECS CPU - drempel 70% (auto-scale-out trigger, REQ-NCA-P1-04)"
      namespace = "AWS/ECS"
      metric    = "CPUUtilization"
      threshold = 70
      unit      = "percent"
      max       = 100
      dims = [
        { key = "ClusterName", value = local.cluster_name },
        { key = "ServiceName", value = local.service_name },
      ]
    },
    {
      title     = "ECS Memory - drempel 80% van container limit (OOM-preventie)"
      namespace = "ECS/ContainerInsights"
      metric    = "memory_utilization"
      threshold = 80
      unit      = "percent"
      max       = 100
      dims = [
        { key = "ClusterName", value = local.cluster_name },
        { key = "ServiceName", value = local.service_name },
      ]
    },
    {
      title     = "ALB Target Response Time - drempel 500ms (latency, REQ-NCA-P1-05)"
      namespace = "AWS/ApplicationELB"
      metric    = "TargetResponseTime"
      threshold = 0.5
      unit      = "s"
      max       = 2
      dims = [
        { key = "LoadBalancer", value = local.alb_dim },
      ]
    },
    {
      title     = "RDS MariaDB CPU - drempel 85% (verticaal opschalen)"
      namespace = "AWS/RDS"
      metric    = "CPUUtilization"
      threshold = 85
      unit      = "percent"
      max       = 100
      dims = [
        { key = "DBInstanceIdentifier", value = local.rds_dim },
      ]
    },
    {
      title     = "ALB Gezonde hosts (HA-controle: moet gelijk zijn aan het aantal taken)"
      namespace = "AWS/ApplicationELB"
      metric    = "HealthyHostCount"
      threshold = null
      unit      = "short"
      max       = null
      dims = [
        { key = "LoadBalancer", value = local.alb_dim },
        { key = "TargetGroup", value = "targetgroup/ecs-nginx-tg-blue/*" },
      ]
    },
    {
      title     = "ALB 5xx-fouten per minuut - drempel 1% van totaal (primaire storingsindicator)"
      namespace = "AWS/ApplicationELB"
      metric    = "HTTPCode_Target_5XX_Count"
      threshold = null
      unit      = "short"
      max       = null
      dims = [
        { key = "LoadBalancer", value = local.alb_dim },
      ]
    },
  ]

  dashboard = {
    uid           = "nca-overview"
    title         = "NCA - Infrastructuur & Applicatie (REQ-NCA-P1-05)"
    description   = "Vaste kijk op de metrieken uit het ontwerpdocument. Gegenereerd door Terraform (monitoring.tf), dus altijd in sync met de werkelijke resourcenamen."
    tags          = ["nca", "auto-generated-by-terraform"]
    timezone      = "browser"
    schemaVersion = 39
    version       = 1
    editable      = false
    refresh       = "30s"

    time = { from = "now-6h", to = "now" }
    panels = concat(
      [
        for idx, p in local.panels : {
          type       = "timeseries"
          id         = idx + 1
          title      = p.title
          gridPos    = { h = 8, w = 12, x = (idx % 2) * 12, y = floor(idx / 2) * 8 }
          datasource = { type = "cloudwatch", uid = local.cw_uid }
          targets = [{
            refId      = "A"
            id         = 1
            region     = var.aws_region
            namespace  = p.namespace
            metricName = p.metric
            stat       = "Average"
            period     = 60
            hide       = false
            dimensions = p.dims
            datasource = { type = "cloudwatch", uid = local.cw_uid }
          }]
          fieldConfig = {
            defaults = {
              unit  = p.unit
              min   = 0
              max   = p.max
              color = { mode = "thresholds" }
              thresholds = {
                mode = "absolute"
                steps = p.threshold == null ? [{ color = "green", value = null }] : [
                  { color = "green", value = null },
                  { color = "red", value = p.threshold },
                ]
              }
              custom = {
                drawStyle   = "line"
                lineWidth   = 2
                fillOpacity = 10
                showPoints  = "never"
              }
            }
            overrides = []
          }
          options = {
            legend  = { displayMode = "list", placement = "bottom", calcs = ["mean", "max"] }
            tooltip = { mode = "multi", sort = "desc" }
          }
        }
      ],
      [
        {
          type       = "timeseries"
          id         = 90
          title      = "NGINX requests (Prometheus / nginx-prometheus-exporter) - leeg zolang cross-VPC DNS niet is opgezet, zie TESTPLAN.md T4"
          gridPos    = { h = 8, w = 24, x = 0, y = 24 }
          datasource = { type = "prometheus", uid = local.prom_uid }
          targets = [
            {
              refId        = "A"
              expr         = "sum(rate(nginx_http_requests_total[5m])) by (status)"
              legendFormat = "status {{status}}"
              datasource   = { type = "prometheus", uid = local.prom_uid }
            },
            {
              refId        = "B"
              expr         = "sum(rate(nginx_connections_active[5m]))"
              legendFormat = "actieve connecties"
              datasource   = { type = "prometheus", uid = local.prom_uid }
            },
          ]
          fieldConfig = {
            defaults = {
              unit   = "short"
              custom = { drawStyle = "line", lineWidth = 2, fillOpacity = 10 }
            }
            overrides = []
          }
          options = {
            legend  = { displayMode = "list", placement = "bottom" }
            tooltip = { mode = "multi" }
          }
        },
      ],
    )
  }
}

locals {
  monitoring_user_data = <<-EOF
    #!/bin/bash
    # Alles hier is idempotent: herhaald uitvoeren is veilig.
    set -euo pipefail

    dnf install -y docker
    systemctl enable --now docker

    # docker-compose v2 als losse binary.
    if ! command -v docker-compose >/dev/null 2>&1; then
      curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 -o /usr/local/bin/docker-compose
      chmod +x /usr/local/bin/docker-compose
    fi

    mkdir -p /opt/monitoring/grafana/provisioning/datasources
    mkdir -p /opt/monitoring/grafana/provisioning/dashboards
    mkdir -p /opt/monitoring/grafana/dashboards

    cat > /opt/monitoring/prometheus.yml <<'PROM'
    global:
      scrape_interval: 15s
    scrape_configs:
      - job_name: 'prometheus'
        static_configs:
          - targets: ['localhost:9090']
      # De ECS-taken registreren zich bij Cloud Map in namespace
      # 'internal.local' binnen de Spoke-Web VPC (zie compute.tf). De
      # nginx-prometheus-exporter draait als sidecar op poort 9113.
      #
      # LET OP: deze private DNS-zone is gekoppeld aan de Spoke-Web VPC, terwijl
      # Prometheus in de Hub-VPC draait. Cross-VPC private DNS via Transit
      # Gateway werkt niet zonder Route 53 Resolver Inbound Endpoint. Zonder
      # die resolutie blijft deze job leeg; de overige panelen draaien op
      # CloudWatch en blijven wel werken. Diagnose + oplossing: TESTPLAN.md T4.
      - job_name: 'nginx-web'
        dns_sd_configs:
          - names: ['web.internal.local']
            type: 'A'
            port: 9113
    PROM

    cat > /opt/monitoring/grafana/provisioning/datasources/datasources.yml <<'DS'
    apiVersion: 1
    deleteDatasources:
      - name: Prometheus
        orgId: 1
      - name: CloudWatch
        orgId: 1
    datasources:
      - name: Prometheus
        uid: prometheus
        type: prometheus
        access: proxy
        url: http://prometheus:9090
        isDefault: false
      - name: CloudWatch
        uid: cloudwatch
        type: cloudwatch
        access: proxy
        jsonData:
          authType: default
          defaultRegion: ${var.aws_region}
    DS

    cat > /opt/monitoring/grafana/provisioning/dashboards/dashboards.yml <<'DASHPROV'
    apiVersion: 1
    providers:
      - name: 'nca'
        orgId: 1
        folder: 'NCA'
        type: file
        disableDeletion: true
        allowUiUpdates: false
        updateIntervalSeconds: 30
        options:
          path: /opt/monitoring/grafana/dashboards
          foldersFromFilesStructure: false
    DASHPROV

    cat > /opt/monitoring/grafana/dashboards/nca-overview.json <<'DASH'
    ${jsonencode(local.dashboard)}
    DASH

    cat > /opt/monitoring/docker-compose.yml <<'DC'
    services:
      prometheus:
        image: ${var.prometheus_image}
        restart: unless-stopped
        volumes:
          - /opt/monitoring/prometheus.yml:/etc/prometheus/prometheus.yml:ro
          - prometheus-data:/prometheus
        command:
          - --config.file=/etc/prometheus/prometheus.yml
          - --storage.tsdb.path=/prometheus
        ports:
          - "9090:9090"

      grafana:
        image: ${var.grafana_image}
        restart: unless-stopped
        depends_on:
          - prometheus
        environment:
          - GF_SECURITY_ADMIN_PASSWORD=${random_password.grafana_admin.result}
          - GF_USERS_ALLOW_SIGN_UP=false
          - GF_AUTH_ANONYMOUS_ENABLED=false
          - GF_ANALYTICS_REPORTING_ENABLED=false
        volumes:
          - /opt/monitoring/grafana/provisioning:/etc/grafana/provisioning:ro
          - /opt/monitoring/grafana/dashboards:/var/lib/grafana/dashboards:ro
          - grafana-data:/var/lib/grafana
        ports:
          - "3000:3000"

    volumes:
      prometheus-data:
      grafana-data:
    DC

    cd /opt/monitoring
    /usr/local/bin/docker-compose up -d
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
