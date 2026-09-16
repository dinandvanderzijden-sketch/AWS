terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # REQ-NCA-P1-06: statefile wordt centraal, veilig en met locking gehost.
  # Zie backend.tf voor de exacte S3/DynamoDB configuratie.
  backend "s3" {
    # Waarden worden meegegeven via `-backend-config` in de CI/CD pipeline
    # (zie .github/workflows/terraform.yml) zodat dit bestand generiek
    # blijft voor meerdere omgevingen (dev/staging/production).
  }
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
