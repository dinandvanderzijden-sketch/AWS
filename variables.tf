# ============================================================
# Variabelen
#
# Principe: alles wat een security-impact heeft staat FAIL-CLOSED.
# Een variabele die je niet expliciet zet, is NIET "iedereen mag dit".
# ============================================================

variable "aws_region" {
  description = "AWS Regio"
  type        = string
  default     = "eu-west-1"
}

# --- Beheerlaag (REQ-NCA-P1-02) --------------------------------

variable "admin_cidr" {
  description = <<-EOT
    CIDR die toegang krijgt tot SSH, Grafana (3000) en Prometheus (9090) op de
    management-instance. LEVE EMPTY om niets publiek te zetten - dat is de
    veilige default. Vul je eigen /32 in (bv. via https://whatismyip.com) om de
    dashboards te bekijken:

        terraform apply -var 'admin_cidr=x.x.x.x/32'
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.admin_cidr == "" || (can(cidrnetmask(var.admin_cidr)) && trimspace(var.admin_cidr) != "0.0.0.0/0")
    error_message = "admin_cidr mag leeg zijn (fail-closed) of een specifiek CIDR-blok zijn, maar NIET 0.0.0.0/0. Prometheus heeft geen authenticatie; zet je eigen /32 of laat de variabele leeg."
  }
}

variable "alert_email" {
  description = <<-EOT
    E-mailadres dat een bevestigingsmail krijgt om zich aan te melden op de
    SNS-topic; na bevestiging ontvangt het alle alarmmeldingen (REQ-NCA-P1-05:
    "een overschrijding van kritieke drempelwaarden triggert binnen 1 minuut een
    notificatie"). Leeg laten = alarms worden wel aangemaakt en zichtbaar in
    CloudWatch, maar er gaat geen mail uit.
  EOT
  type        = string
  default     = ""
}

variable "key_pair_name" {
  description = "Naam van een bestaand EC2 key pair voor SSH-toegang tot de management-instance. Laat leeg = geen SSH; toegang loopt dan via AWS SSM Session Manager (aanbevolen, geen open poort 22 nodig)."
  type        = string
  default     = ""
}

# --- Applicatie (REQ-NCA-P1-03, P1-04) ---------------------------

variable "db_username" {
  description = "Master username voor de MariaDB database"
  type        = string
  default     = "dbadmin"
}

variable "max_task_count" {
  description = <<-EOT
    Maximum aantal ECS-taken bij piekbelasting (REQ-NCA-P1-04). De TCO-analyse
    gaat uit van een piek van 10 taken; met de huidige sandbox-SCP is 4 een
    verstandiger bovengrens. Verhoog dit als de loadtest aantoont dat 4 taken
    de piek niet aankunnen.
  EOT
  type        = number
  default     = 4

  validation {
    condition     = var.max_task_count >= 2
    error_message = "max_task_count moet minimaal 2 zijn (de HA-eis is minimaal 2 NGINX-taken over 2 AZ's)."
  }
}

variable "enable_spoke_endpoints" {
  description = <<-EOT
    Maak VPC-endpoints aan in het Spoke-Web zodat de ECS-taken de AWS-API's
    bereiken zonder via de NAT Gateway te lopen. Zet op false om ze te verwijderen.

    LET OP: dit is geen optimalisatie maar een noodzaak. Zonder deze endpoints
    blijven de taken 4+ minuten op PENDING staan en sterven ze met "connection
    issue between the task and Amazon CloudWatch". Zie TESTPLAN.md T13.3.
  EOT
  type        = bool
  default     = true
}

# --- Monitoring (REQ-NCA-P1-05) ---------------------------------

variable "grafana_image" {
  description = "Grafana-image voor de observability-stack. Gepind op een exacte versie zodat een re-run reproduceerbaar is (een ':latest' kan stilletjes een breaking change meenemen)."
  type        = string
  default     = "grafana/grafana:13.2.3"
}

variable "prometheus_image" {
  description = "Prometheus-image voor de observability-stack. Gepind op een exacte versie om dezelfde reden als bij grafana_image."
  type        = string
  default     = "prom/prometheus:v3.15.0"
}

# --- CI/CD (REQ-NCA-P1-07) --------------------------------------

variable "github_repo" {
  description = "GitHub-repository als 'owner/repo'. Bepaalt wie de rol uit oidc.tf mag overnemen: alleen een push naar main in deze repo. Wordt ook gebruikt om de self-hosted runner in runner.tf te registreren."
  type        = string
  default     = "dinandvanderzijden-sketch/AWS"
}

# Sinds 15 juli 2026 stuurt GitHub in de 'sub'-claim numerieke IDs mee naast
# de namen. De trust policy in oidc.tf accepteert beide vormen, dus deze twee
# zijn alleen nodig voor de nieuwe. Wil je ze opzoeken: open de repo op
# github.com, en haal de IDs uit het OIDC-token (of uit een mislukte
# AssumeRoleWithWebIdentity-foutmelding, die de sub-claim volledig toont).
variable "github_owner_id" {
  description = "Numerieke ID van de GitHub-eigenaar, voor de sub-claim van het OIDC-token."
  type        = string
  default     = "229950911"
}

variable "github_repo_id" {
  description = "Numerieke ID van de GitHub-repository, voor de sub-claim van het OIDC-token."
  type        = string
  default     = "1372748269"
}

variable "tfstate_bucket" {
  description = "Bucket waarin de Terraform-state ligt. De rol uit oidc.tf krijgt hier lees- en schrijfrechten op, zodat de pipeline de backend kan openen."
  type        = string
  default     = "tfstate-eu-west-1-491799435972"
}

variable "enable_self_hosted_runner" {
  description = <<-EOT
    Provision een self-hosted GitHub Actions-runner op EC2 in het Management
    Subnet (REQ-NCA-P1-07). Standaard false, omdat de workflow pas naar
    'runs-on: [self-hosted, linux]' mag wijzen als de runner ook daadwerkelijk
    geregistreerd en online is - anders blijft de hele pipeline steken.

    Zie runner.tf en TESTPLAN.md (test T7) voor het inschakelen.
  EOT
  type        = bool
  default     = false
}
