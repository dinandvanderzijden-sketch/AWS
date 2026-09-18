terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  backend "s3" {
    bucket = "innovation-bucket" 
    key    = "terraform/state.tfstate"
    region = "us-east-1"
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  default     = "eu-west-1"
  description = "AWS Regio"
}

output "alb_dns_name" {
  value       = aws_lb.external_alb.dns_name
  description = "Publieke URL van de Load Balancer"
}

output "ecr_repository_url" {
  value       = aws_ecr_repository.app.repository_url
  description = "ECR Repository URL"
}