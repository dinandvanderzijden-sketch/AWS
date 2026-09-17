
resource "aws_db_subnet_group" "this" {
  name       = "${var.project_name}-db-subnets"
  subnet_ids = aws_subnet.database_private[*].id
  tags       = { Name = "${var.project_name}-db-subnets" }
}

# Terraform genereert het wachtwoord zelf; het staat alleen (versleuteld) in
# Secrets Manager, nooit ergens in leesbare tekst gelogd.
resource "random_password" "db" {
  length  = 24
  special = false # voorkomt escaping-issues in connectiestrings
}

resource "aws_secretsmanager_secret" "db" {
  name = "${var.project_name}/${var.environment}/db-credentials"
  tags = { Name = "${var.project_name}-db-secret" }
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

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true # gebruikt de standaard AWS-beheerde RDS-sleutel

  db_name  = var.db_name
  username = var.db_username
  password = random_password.db.result

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.database.id]

  publicly_accessible = false # REQ-NCA-P1-02: nooit een publiek IP-adres
  multi_az            = var.db_multi_az

  backup_retention_period = 7
  backup_window           = "02:00-03:00"
  maintenance_window      = "sun:03:30-sun:04:30"
  deletion_protection     = var.db_deletion_protection
  skip_final_snapshot     = !var.db_deletion_protection

  tags = { Name = "${var.project_name}-db" }
}
