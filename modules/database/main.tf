# =============================================================================
# DATABASE MODULE — Amazon RDS for MariaDB, Multi-AZ, privé, encrypted.
# REQ-NCA-P1-02 (secure access) + ontwerp: encryptie, 7 dagen backups, PITR.
# =============================================================================

resource "aws_db_subnet_group" "this" {
  name       = "${var.project_name}-db-subnets"
  subnet_ids = var.spoke_data_subnet_ids
  tags       = { Name = "${var.project_name}-db-subnets" }
}

resource "aws_kms_key" "db" {
  description             = "KMS-key voor RDS encryptie-at-rest (AES-256)."
  deletion_window_in_days = 30
  enable_key_rotation     = true
  tags                    = { Name = "${var.project_name}-db-kms" }
}

resource "aws_kms_alias" "db" {
  name          = "alias/${var.project_name}-db"
  target_key_id = aws_kms_key.db.key_id
}

# Wachtwoord wordt door Terraform gegenereerd en NOOIT in git/state-diffs
# leesbaar gelogd; het staat alleen versleuteld in Secrets Manager.
resource "random_password" "db" {
  length  = 24
  special = false # MariaDB-compatibele connectiestrings; alfanumeriek voorkomt escaping-issues
}

resource "aws_secretsmanager_secret" "db" {
  name       = "${var.project_name}/${var.environment}/db-credentials"
  kms_key_id = aws_kms_key.db.key_id
  tags       = { Name = "${var.project_name}-db-secret" }
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    engine   = "mariadb"
    username = var.db_username
    password = random_password.db.result
    host     = aws_db_instance.this.address
    port     = 3306
    dbname   = var.db_name
  })
}

resource "aws_db_instance" "this" {
  identifier     = "${var.project_name}-db"
  engine         = "mariadb"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  allocated_storage     = 50
  max_allocated_storage  = 200
  storage_type           = "gp3"
  storage_encrypted      = true
  kms_key_id              = aws_kms_key.db.arn

  db_name  = var.db_name
  username = var.db_username
  password = random_password.db.result

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.database_sg_id]

  # REQ-NCA-P1-02: geen publiek IP-adres, uitsluitend privé bereikbaar.
  publicly_accessible = false
  multi_az             = true

  backup_retention_period = 7
  backup_window            = "02:00-03:00"
  maintenance_window       = "sun:03:30-sun:04:30"
  copy_tags_to_snapshot    = true
  deletion_protection      = true
  skip_final_snapshot      = false
  final_snapshot_identifier = "${var.project_name}-db-final"

  # In-transit encryptie: forceert TLS/SSL connecties.
  parameter_group_name = aws_db_parameter_group.this.name

  tags = { Name = "${var.project_name}-db" }
}

resource "aws_db_parameter_group" "this" {
  name   = "${var.project_name}-mariadb-params"
  family = "mariadb10.11"

  parameter {
    name  = "require_secure_transport"
    value = "ON"
  }

  tags = { Name = "${var.project_name}-mariadb-params" }
}
