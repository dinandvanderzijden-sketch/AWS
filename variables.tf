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
