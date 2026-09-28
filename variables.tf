variable "admin_cidr" {
  description = "CIDR die toegang krijgt tot SSH, Grafana en Prometheus op de management/bastion-instance. Zet dit naar jouw eigen IP/32 zodra je die weet (bv. via whatismyip.com) i.p.v. 0.0.0.0/0."
  type        = string
  default     = "0.0.0.0/0"
}

variable "db_username" {
  description = "Master username voor de MariaDB database"
  type        = string
  default     = "dbadmin"
}

variable "key_pair_name" {
  description = "Naam van een bestaand EC2 key pair voor SSH-toegang tot de monitoring/bastion-instance. Laat leeg om zonder SSH-key te draaien (dan kun je alleen via Session Manager/console in)."
  type        = string
  default     = ""
}

variable "github_repo" {
  description = "OWNER/REPO van de GitHub-repository die via OIDC naar AWS mag deployen. Wordt gebruikt voor de IAM trust-policy ('repo:<OWNER/REPO>:...')."
  type        = string
  default     = "dinandvanderzijden-sketch/AWS"
}

variable "github_branch" {
  description = "Branch die mag deployen naar AWS. Elke push naar deze branch mag de deploy-role overnemen; andere branches niet."
  type        = string
  default     = "main"
}

variable "tfstate_bucket" {
  description = "Bucket met de Terraform state (zelfde bucket als de 'backend \"s3\"' block in main.tf). De IAM-rol die 'terraform init/plan/apply' draait heeft hier lees- en schrijfrechten op nodig."
  type        = string
  default     = "tfstate-eu-west-1-491799435972"
}

variable "enable_pr_plan_role" {
  description = "Maak de read-only plan-role ook toegankelijk voor pull_request-events. LET OP: dit maakt de rol assimilabel voor iedereen die een PR opent (ook vanuit een fork). De rol is read-only, maar zet dit op false als je dit niet wilt."
  type        = bool
  default     = true
}
