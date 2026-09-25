# ============================================================
# Geheim: database wachtwoord (niet langer hardcoded in de repo)
# ============================================================
resource "random_password" "db_password" {
  length           = 20
  special          = true
  override_special = "!#$%^&*()-_=+"
}

resource "aws_secretsmanager_secret" "db_credentials" {
  name        = "prod/mariadb/credentials"
  description = "MariaDB credentials - ECS taken halen dit tijdens runtime op"
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = aws_secretsmanager_secret.db_credentials.id
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db_password.result
  })
}

# ============================================================
# Encryptie-at-rest (AWS KMS, AES-256)
# ============================================================
resource "aws_kms_key" "rds" {
  description             = "KMS key voor RDS MariaDB encryption-at-rest"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_kms_alias" "rds" {
  name          = "alias/rds-mariadb"
  target_key_id = aws_kms_key.rds.key_id
}

# Forceert TLS/SSL in-transit richting de database
resource "aws_db_parameter_group" "mariadb_tls" {
  name   = "mariadb-require-tls"
  family = "mariadb10.11"

  parameter {
    name  = "require_secure_transport"
    value = "1"
  }
}

resource "aws_db_subnet_group" "db_subnets" {
  name       = "db-subnet-group"
  subnet_ids = [aws_subnet.data_private_a.id, aws_subnet.data_private_b.id]
}

resource "aws_db_instance" "mariadb" {
  allocated_storage    = 20
  engine                = "mariadb"
  engine_version        = "10.11"
  instance_class        = "db.t3.micro" # Fontys-sandbox SCP blokkeert grotere instance-klassen
  db_name                = "appdb"
  username                = var.db_username
  password                = random_password.db_password.result
  db_subnet_group_name    = aws_db_subnet_group.db_subnets.name
  vpc_security_group_ids  = [aws_security_group.db_sg.id]
  parameter_group_name    = aws_db_parameter_group.mariadb_tls.name

  publicly_accessible = false
  multi_az             = true
  storage_encrypted    = true
  kms_key_id            = aws_kms_key.rds.arn

  backup_retention_period = 7
  backup_window            = "03:00-04:00"
  copy_tags_to_snapshot    = true
  skip_final_snapshot      = true # sandbox: zet dit op false + final_snapshot_identifier voor een echte productieomgeving

  tags = { Name = "appdb-mariadb" }
}
