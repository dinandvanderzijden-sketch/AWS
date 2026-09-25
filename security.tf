# Load Balancer Security Group (publiek HTTP; 443 alvast open voor als je later
# een domein + ACM-certificaat toevoegt - er is nu nog geen HTTPS-listener)
resource "aws_security_group" "alb_sg" {
  name        = "alb-sg"
  description = "Allow public HTTP/HTTPS"
  vpc_id      = aws_vpc.hub.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Gereserveerd voor HTTPS zodra er een ACM-certificaat + domein is"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "alb-sg" }
}

# Web Server SG (NGINX/ECS) - in de Spoke-Web VPC
resource "aws_security_group" "web_sg" {
  name        = "web-ecs-sg"
  description = "Allow HTTP from ALB + telemetry scraping from mgmt; egress to DB + AWS APIs"
  vpc_id      = aws_vpc.spoke_web.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["10.0.2.0/24", "10.0.3.0/24"] # vanuit Hub ALB
  }

  ingress {
    from_port   = 9113
    to_port     = 9113
    protocol    = "tcp"
    cidr_blocks = ["10.0.1.0/24"] # nginx-exporter scraping vanuit Mgmt-subnet
    description = "Prometheus scrape (nginx-prometheus-exporter)"
  }

  egress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = ["10.3.0.0/16"] # naar Database SG
  }

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "AWS APIs (ECR pull, Secrets Manager, CloudWatch Logs) via NAT. Het ontwerpdocument beperkt egress tot poort 3306, maar dat blokkeert image-pulls en secret-injectie - vandaar deze aanvulling."
  }

  tags = { Name = "web-ecs-sg" }
}

# Database SG (MariaDB) - REQ-NCA-P1-02: geen publiek IP, uitsluitend bereikbaar via Web-spoke
resource "aws_security_group" "db_sg" {
  name        = "db-maria-sg"
  description = "Allow MariaDB from Web spoke only + exporter scraping from mgmt"
  vpc_id      = aws_vpc.spoke_data.id

  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = ["10.1.0.0/16"]
  }

  ingress {
    from_port   = 9104
    to_port     = 9104
    protocol    = "tcp"
    cidr_blocks = ["10.0.1.0/24"] # mysqld_exporter scraping vanuit Mgmt-subnet
    description = "MariaDB exporter poort (het ontwerpdocument noemt 9187, dat is de Postgres-exporterpoort; 9104 is de standaard MySQL/MariaDB-exporterpoort)"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "db-maria-sg" }
}

# Management/Bastion SG - CI/CD-plek + Prometheus/Grafana
resource "aws_security_group" "mgmt_sg" {
  name        = "mgmt-sg"
  description = "SSH + Grafana/Prometheus UI vanaf admin_cidr; vrije egress voor scraping/CI"
  vpc_id      = aws_vpc.hub.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  ingress {
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
    description = "Grafana UI"
  }

  ingress {
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
    description = "Prometheus UI"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "mgmt-sg" }
}
