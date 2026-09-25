terraform {
  required_version = ">= 1.5.0"
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
  backend "s3" {
    bucket = "tfstate-eu-west-1-491799435972" # De zojuist aangemaakte bucket
    key    = "terraform/state.tfstate"
    region = "eu-west-1"                       # Nu correct op eu-west-1
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  default     = "eu-west-1"
  description = "AWS Regio"
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

output "grafana_url" {
  value       = "http://${aws_instance.monitoring.public_ip}:3000"
  description = "Grafana dashboard - login met admin / (zie output grafana_admin_password)"
}

output "prometheus_url" {
  value       = "http://${aws_instance.monitoring.public_ip}:9090"
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
