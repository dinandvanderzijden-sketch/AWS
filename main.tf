# =============================================================================
# main.tf — provider setup + gedeelde data sources.
#
# Dit project bestaat uit een handvol platte .tf-bestanden, geen modules.
# Terraform leest gewoon ALLE .tf-bestanden in deze map samen als één geheel
# — de opsplitsing hieronder is alleen voor de leesbaarheid:
#
#   network.tf        VPC, subnets, internet-toegang
#   security.tf        Security Groups (firewall-regels)
#   database.tf         RDS MariaDB
#   compute.tf           ALB + ECS Fargate (de NGINX-webservice)
#   cicd.tf               GitHub Actions self-hosted runner
#   observability.tf     Prometheus + Grafana
#   variables.tf / outputs.tf
# =============================================================================

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Waarden komen via -backend-config uit de CI/CD pipeline, zodat dit
  # bestand generiek blijft. Zie environments/bootstrap/ voor het aanmaken
  # van de S3-bucket + DynamoDB-tabel hierachter (eenmalig, lokaal).
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

# Amazon Linux 2023 AMI, gebruikt door zowel de CI/CD-runner als de
# observability-instance.
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}
