# =============================================================================
# variables.tf — alle instelbare waarden op één plek.
# =============================================================================

variable "aws_region" {
  type    = string
  default = "eu-west-1"
}

variable "project_name" {
  type    = string
  default = "innovatech-webplatform"
}

variable "environment" {
  type    = string
  default = "production"
}

# --- Netwerk (één VPC, 3 lagen: publiek / privé-web / privé-data) ----------

variable "hub_vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "web_vpc_cidrs" {
  description = "CIDRs for the two web spoke VPCs."
  type        = list(string)
  default     = ["10.1.0.0/16", "10.2.0.0/16"]
}

variable "database_vpc_cidr" {
  type    = string
  default = "10.3.0.0/16"
}

variable "hub_public_subnet_cidrs" {
  description = "Public hub subnets for the ALB and management instances."
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "hub_private_subnet_cidrs" {
  description = "Private hub subnets used for the TGW attachment."
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24"]
}

variable "web_public_subnet_cidrs" {
  description = "Public subnets for NAT gateways in the web spokes."
  type        = list(string)
  default     = ["10.1.1.0/24", "10.2.1.0/24"]
}

variable "web_private_subnet_cidrs" {
  description = "Private subnet for the NGINX server in each web spoke."
  type        = list(string)
  default     = ["10.1.11.0/24", "10.2.11.0/24"]
}

variable "database_private_subnet_cidrs" {
  description = "Private RDS subnets in the database spoke."
  type        = list(string)
  default     = ["10.3.11.0/24", "10.3.12.0/24"]
}

variable "admin_cidr" {
  description = "Jouw IP/VPN-CIDR voor SSH naar de runner/observability-VM's en toegang tot Grafana."
  type        = string
  # LET OP: pas dit aan — 0.0.0.0/0 mag hier nooit blijven staan.
  default = "0.0.0.0/0"
}

variable "web_instance_type" {
  type    = string
  default = "t3.micro"
}

# --- Webservice --------------------------------------------------------------

variable "container_image" {
  type    = string
  default = "nginx:1.27-alpine"
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
  description = "Minimaal 2, verspreid over 2 AZ's (REQ-NCA-P1-04)."
  type        = number
  default     = 2
}

variable "ecs_max_tasks" {
  type    = number
  default = 6
}

variable "ecs_cpu_target" {
  description = "Streefwaarde (%) voor autoscaling; ECS voegt/verwijdert taken om hierbij te blijven."
  type        = number
  default     = 70
}

# --- Database ----------------------------------------------------------------

variable "db_engine_version" {
  type    = string
  default = "10.11"
}

variable "db_instance_class" {
  description = "Fontys-sandbox SCP's staan vaak alleen free-tier-instances toe."
  type        = string
  default     = "db.t3.micro"
}

variable "db_multi_az" {
  description = "Multi-AZ kan door kostenbeperkende SCP's geblokkeerd worden."
  type        = bool
  default     = false
}

variable "db_deletion_protection" {
  description = "Zet aan voor echte productie; uit houdt het makkelijker om tijdens het leren opnieuw op te bouwen."
  type        = bool
  default     = false
}

variable "db_name" {
  type    = string
  default = "innovatech"
}

variable "db_username" {
  type    = string
  default = "dbadmin"
}

# --- CI/CD ---------------------------------------------------------------------

variable "github_org" {
  type = string
}

variable "github_repo" {
  type = string
}

variable "github_runner_token" {
  description = "Kortlevend registratietoken, via GitHub opgehaald — nooit hardcoded."
  type        = string
  sensitive   = true
}

variable "runner_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "key_pair_name" {
  description = "Bestaande EC2 key pair voor noodgevallen-SSH. Laat null als je die niet hebt."
  type        = string
  default     = null
}
