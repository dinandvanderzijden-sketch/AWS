# =============================================================================
# security.tf — firewall-regels. Alles zit in dezelfde VPC, dus elke regel
# hieronder verwijst gewoon naar de security group van de "buur" in plaats
# van naar IP-reeksen — dat is korter én je hoeft nooit een CIDR bij te
# werken als een subnet verandert.
# =============================================================================

# 1) ALB: open voor internet op 80/443.
resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb-sg"
  description = "Inkomend HTTP/HTTPS vanaf internet."
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-alb-sg" }
}

# 2) Webserver (ECS/NGINX): alleen bereikbaar vanaf de ALB.
resource "aws_security_group" "web" {
  name        = "${var.project_name}-web-sg"
  description = "Inkomend uitsluitend vanaf de ALB."
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "HTTP van de ALB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"] # nodig voor ECR image pulls, Secrets Manager, CloudWatch
  }

  tags = { Name = "${var.project_name}-web-sg" }
}

# 3) Database: alleen bereikbaar vanaf de webservers, nergens anders vandaan.
resource "aws_security_group" "database" {
  name        = "${var.project_name}-db-sg"
  description = "Inkomend SQL-verkeer uitsluitend vanaf de webserver."
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "MariaDB vanaf de webserver"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.web.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-db-sg" }
}

# 4) Management (CI/CD-runner + Prometheus/Grafana): SSH en Grafana-UI
# uitsluitend vanaf jouw eigen IP/VPN (admin_cidr).
resource "aws_security_group" "management" {
  name        = "${var.project_name}-mgmt-sg"
  description = "SSH + Grafana uitsluitend vanaf admin_cidr."
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "SSH (beperk admin_cidr in productie!)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  ingress {
    description = "Grafana dashboard"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-mgmt-sg" }
}

# Prometheus (management-SG) mag de NGINX-exporter op de webservers bevragen.
resource "aws_security_group_rule" "web_allow_scrape" {
  type                     = "ingress"
  security_group_id        = aws_security_group.web.id
  source_security_group_id = aws_security_group.management.id
  from_port                = 9100
  to_port                  = 9187
  protocol                 = "tcp"
  description               = "Prometheus scraped exporters (node/nginx/mysql)"
}
