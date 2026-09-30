terraform {
  # >= 1.10 is nodig voor 'use_lockfile' in de backend hieronder.
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # REQ-NCA-P1-06: "Statefiles worden veilig gehost in een centrale,
  # vergrendelde storage-bucket (met remote locking)."
  #
  # 'use_lockfile = true' zet het native S3-lockfile-mechanisme aan (Terraform
  # >= 1.10): voor elke plan/apply wordt een lease-bestand in de bucket
  # geplaatst en een tweede gelijktijdige run wacht tot de eerste klaar is.
  # Dat vervangt de oudere DynamoDB-tabel zonder extra kosten en zonder het
  # kip-een-probleem waarbij die tabel nog moet bestaan voordat
  # 'terraform init' de backend kan openen.
  #
  # LET OP: de state bevat het DB-wachtwoord en het Grafana-wachtwoord in
  # plaintext. Versiebeheer is hier dus geen 'nice-to-have' maar een
  # voorwaarde voor terugdraaien naar een vorige versie van de infrastructuur.
  # Zet encryptie aan als de bucket dat nog niet heeft:
  #   aws s3api put-bucket-encryption --bucket <bucket> ... (AES256)
  backend "s3" {
    bucket       = "tfstate-eu-west-1-491799435972"
    key          = "terraform/state.tfstate"
    region       = "eu-west-1"
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region
}

# ============================================================
# Outputs - dit zijn de dingen die je na 'terraform apply' opvraagt
# ============================================================

output "alb_dns_name" {
  value       = aws_lb.external_alb.dns_name
  description = "Publieke URL van de website (open dit in je browser, http://...)"
}

output "ecr_repository_url" {
  value       = aws_ecr_repository.app.repository_url
  description = "ECR Repository URL (hierheen push je met docker/GitHub Actions)"
}

output "monitoring_instance_public_ip" {
  value       = aws_instance.monitoring.public_ip
  description = "Publiek IP van de Prometheus/Grafana-instance. Alleen bereikbaar als var.admin_cidr gezet is."
}

output "grafana_url" {
  value       = var.admin_cidr == "" ? "NIET BEREIKBAAR - zet -var 'admin_cidr=<jouw-ip>/32' en apply opnieuw" : "http://${aws_instance.monitoring.public_ip}:3000"
  description = "Grafana dashboard - login met admin / (zie output grafana_admin_password)"
}

output "prometheus_url" {
  value       = var.admin_cidr == "" ? "NIET BEREIKBAAR - zet -var 'admin_cidr=<jouw-ip>/32' en apply opnieuw" : "http://${aws_instance.monitoring.public_ip}:9090"
  description = "Prometheus UI"
}

output "grafana_admin_password" {
  value       = random_password.grafana_admin.result
  sensitive   = true
  description = "Grafana admin wachtwoord. Opvragen met: terraform output -raw grafana_admin_password"
}

output "database_endpoint" {
  value       = aws_db_instance.mariadb.address
  description = "Interne DB endpoint (niet publiek bereikbaar, alleen vanuit de web-spoke)"
}

# --- Naamgegevens die de CI/CD-pipeline nodig heeft -------------------
# De workflow hoeft deze namen dan niet meer te hardcoden (REQ-NCA-P1-08:
# git repo is de Single Source of Truth - de infra is dan niet meer de tweede
# bron die uit sync kan raken).

output "ecs_cluster_name" {
  value       = aws_ecs_cluster.main.name
  description = "Naam van de ECS-cluster (voor de GitHub Actions pipeline)."
}

output "ecs_service_name" {
  value       = aws_ecs_service.web.name
  description = "Naam van de ECS-service (voor de GitHub Actions pipeline)."
}

output "codedeploy_app_name" {
  value       = aws_codedeploy_app.web.name
  description = "Naam van de CodeDeploy-applicatie (voor de GitHub Actions pipeline)."
}

output "codedeploy_deployment_group_name" {
  value       = aws_codedeploy_deployment_group.web.deployment_group_name
  description = "Naam van de CodeDeploy-deploymentgroup (voor de GitHub Actions pipeline)."
}

output "sns_alerts_topic_arn" {
  value       = aws_sns_topic.alerts.arn
  description = "SNS-topic waaraan alle CloudWatch-alarms zijn gekoppeld. De notificatie van REQ-NCA-P1-05 loopt hierdoorheen."
}

output "admin_cidr_in_effect" {
  value       = var.admin_cidr
  description = "De CIDR die toegang heeft tot SSH/Grafana/Prometheus. Leeg = niets publiek toegankelijk (fail-closed)."
}
