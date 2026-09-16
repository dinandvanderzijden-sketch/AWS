# =============================================================================
# SECURITY MODULE — implementeert de Firewalling & Security Groups Matrix
# uit het ontwerpdocument. Standaard: Deny All inbound, alles expliciet open.
#
# Let op: Hub, Spoke-Web en Spoke-Data zijn AFZONDERLIJKE VPC's die via een
# Transit Gateway verbonden zijn. Security Groups kunnen elkaar alleen
# refereren BINNEN dezelfde VPC — cross-VPC verkeer via TGW moet daarom op
# CIDR-blok worden toegestaan (dit is ook zo beschreven in het analysedocument:
# "toegestaan vanaf de Web Server Security Group (10.1.0.0/16 en 10.2.0.0/16)").
# =============================================================================

# --- 1. Public Load Balancer SG (in Hub VPC) --------------------------------

resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb-sg"
  description = "Inkomend HTTP/HTTPS vanaf internet naar de ALB."
  vpc_id      = var.hub_vpc_id

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

# --- 2. Web Server SG (NGINX / ECS, in Spoke-Web VPC) -----------------------

resource "aws_security_group" "web" {
  name        = "${var.project_name}-web-sg"
  description = "Inkomend uitsluitend vanaf de ALB (Hub); uitgaand naar DB op 3306."
  vpc_id      = var.spoke_web_vpc_id

  ingress {
    description = "HTTP van de ALB in de Hub"
    from_port   = 80
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = var.hub_public_subnet_cidrs
  }

  egress {
    description = "MariaDB naar de dataspoke"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = [var.spoke_data_vpc_cidr]
  }

  # Egress naar 443 nodig voor ECR/Secrets Manager/CloudWatch/GitHub calls
  # (via NAT Gateway in de Hub).
  egress {
    description = "HTTPS uitgaand (ECR, Secrets Manager, CloudWatch)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Telemetry export naar Prometheus in de Hub management subnet.
  egress {
    description = "Metrics scrape door Prometheus toestaan (response traffic)"
    from_port   = 9113
    to_port     = 9113
    protocol    = "tcp"
    cidr_blocks = [var.hub_mgmt_subnet_cidr]
  }

  tags = { Name = "${var.project_name}-web-sg" }
}

# Los van de "web" SG, zodat Prometheus (in de Hub) de NGINX exporter kan
# bereiken zonder de egress-only regels hierboven te hoeven verruimen.
resource "aws_security_group_rule" "web_allow_scrape_ingress" {
  type              = "ingress"
  security_group_id = aws_security_group.web.id
  description       = "Prometheus (Hub mgmt subnet) scraped de nginx-exporter"
  from_port         = 9113
  to_port           = 9113
  protocol          = "tcp"
  cidr_blocks       = [var.hub_mgmt_subnet_cidr]
}

# --- 3. Database SG (MariaDB, in Spoke-Data VPC) ----------------------------

resource "aws_security_group" "database" {
  name        = "${var.project_name}-db-sg"
  description = "Inkomend SQL-verkeer uitsluitend vanaf de webservers."
  vpc_id      = var.spoke_data_vpc_id

  ingress {
    description = "MariaDB vanaf de webserver-spoke"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = [var.spoke_web_vpc_cidr]
  }

  # Alleen benodigd voor RDS enhanced monitoring / patch-downloads binnen AWS.
  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-db-sg" }
}

# --- 4. Management SG (CI/CD runner, Prometheus/Grafana, Bastion) ----------

resource "aws_security_group" "management" {
  name        = "${var.project_name}-mgmt-sg"
  description = "SSH en telemetry-scraping uitsluitend vanuit het Hub management subnet."
  vpc_id      = var.hub_vpc_id

  ingress {
    description = "SSH (beperk admin_cidr in productie!)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  # Grafana UI, alleen bereikbaar via VPN/Bastion (admin_cidr), nooit publiek.
  ingress {
    description = "Grafana dashboard"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  ingress {
    description = "Prometheus UI"
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = [var.hub_mgmt_subnet_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-mgmt-sg" }
}

# Prometheus (in de mgmt SG) mag de node/database exporters in de spokes
# bevragen op de telemetrie-poorten uit het analysedocument.
resource "aws_security_group_rule" "mgmt_scrape_egress" {
  type              = "egress"
  security_group_id = aws_security_group.management.id
  description       = "Prometheus scraped exporters (9100 node, 9187 postgres/mysql, 9113 nginx)"
  from_port         = 9100
  to_port           = 9187
  protocol          = "tcp"
  cidr_blocks       = [var.spoke_web_vpc_cidr, var.spoke_data_vpc_cidr]
}
