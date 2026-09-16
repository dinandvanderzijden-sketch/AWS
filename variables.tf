variable "aws_region" {
  description = "AWS regio waarin alles wordt uitgerold."
  type        = string
  default     = "eu-west-1"
}

variable "project_name" {
  description = "Korte projectnaam, gebruikt als prefix voor resource-namen en tags."
  type        = string
  default     = "innovatech-webplatform"
}

variable "environment" {
  description = "Omgeving (production, staging, ...)."
  type        = string
  default     = "production"
}

# --- Netwerk: Hub-and-Spoke (REQ-NCA-P1-01) ---------------------------------

variable "hub_vpc_cidr" {
  description = "CIDR van de centrale Hub VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "hub_public_subnet_cidrs" {
  description = "Publieke subnets in de Hub (ALB + IGW), 1 per AZ."
  type        = list(string)
  default     = ["10.0.2.0/24", "10.0.3.0/24"]
}

variable "hub_mgmt_subnet_cidr" {
  description = "Management subnet in de Hub (CI/CD runner, Prometheus/Grafana, Bastion)."
  type        = string
  default     = "10.0.1.0/24"
}

variable "spoke_web_vpc_cidr" {
  description = "CIDR van de Spoke-VPC voor de webservice (NGINX/ECS)."
  type        = string
  default     = "10.1.0.0/16"
}

variable "spoke_web_subnet_cidrs" {
  description = "Private web subnets, verspreid over 2 AZ's (REQ-NCA-P1-04)."
  type        = list(string)
  default     = ["10.1.1.0/24", "10.1.2.0/24"]
}

variable "spoke_data_vpc_cidr" {
  description = "CIDR van de Spoke-VPC voor de database."
  type        = string
  default     = "10.3.0.0/16"
}

variable "spoke_data_subnet_cidrs" {
  description = "Private data subnets voor RDS Multi-AZ."
  type        = list(string)
  default     = ["10.3.1.0/24", "10.3.2.0/24"]
}

variable "admin_cidr" {
  description = "CIDR (bijv. jouw VPN/kantoor-IP) dat SSH naar de management subnet mag maken."
  type        = string
  # LET OP: pas dit aan voor gebruik — 0.0.0.0/0 mag hier nooit blijven staan.
  default = "0.0.0.0/0"
}

# --- Webservice / ECS Fargate (REQ-NCA-P1-03/04) ----------------------------

variable "container_image" {
  description = "NGINX image (bijv. jouw ECR repo:tag) dat op ECS Fargate draait."
  type        = string
  default     = "nginx:1.27-alpine"
}

variable "ecs_task_cpu" {
  type    = number
  default = 256
}

variable "ecs_task_memory" {
  type    = number
  default = 512
}

variable "ecs_min_tasks" {
  description = "Minimaal aantal NGINX-taken (REQ-NCA-P1-04: minimaal 2)."
  type        = number
  default     = 2
}

variable "ecs_max_tasks" {
  type    = number
  default = 6
}

# --- Database (REQ-NCA-P1-02) -----------------------------------------------

variable "db_engine_version" {
  type    = string
  default = "10.11"
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.medium"
}

variable "db_name" {
  type    = string
  default = "innovatech"
}

variable "db_username" {
  type    = string
  default = "dbadmin"
}

# --- CI/CD (REQ-NCA-P1-07/08) -----------------------------------------------

variable "github_org" {
  description = "GitHub org/gebruikersnaam die de self-hosted runner registreert."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository naam."
  type        = string
}

variable "github_runner_token" {
  description = "Kortlevend registratietoken voor de self-hosted runner (via GitHub API/Secrets Manager aangeleverd, nooit hardcoded in git)."
  type        = string
  sensitive   = true
}

variable "runner_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "key_pair_name" {
  description = "Bestaande EC2 key pair voor noodgevallen-SSH naar runner/observability instances."
  type        = string
  default     = null
}
