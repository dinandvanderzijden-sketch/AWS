# ============================================================
# Security Groups - REQ-NCA-P1-01 ("Deny All, expliciet per poort/protocol
# toegestaan") en REQ-NCA-P1-02 ("geen publiek IP op DB/backend").
#
# In AWS is een security group inherently een deny-all: er wordt alleen
# verkeer toegelaten dat je hier expliciet opent. Er staan dus geen
# "deny"-regels in dit bestand - het ontbreken van een regel IS de deny.
# ============================================================

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

  # HTTP vanaf de Application Load Balancer.
  #
  # Het ontwerpdocument schrijft een security-group-referentie voor, maar dat
  # kan hier niet: de ALB draait in de Hub-VPC en deze groep in de
  # Spoke-Web-VPC. AWS accepteert een SG-referentie alleen binnen dezelfde VPC
  # en gooit anders weg met "InvalidGroup.NotFound: You have specified two
  # resources that belong to different networks" (geverifieerd: apply
  # 2026-09-29). Ook met VPC-peering werkt het niet: peering geeft losse
  # routes, geen gedeelde security groups. De enige cross-VPC-optie die AWS
  # biedt is een CIDR-regel.
  #
  # Functioneel gelijkwaardig: een ALB met target_type = ip bewaart het
  # client-IP, dus de pakketten arriveren met het IP van de eindgebruiker als
  # bron. Let op de CIDR-breedte: 10.0.2.0/24 en 10.0.3.0/24 zijn de publieke
  # Hub-subnets, dus alles daarin kan poort 80 bereiken, niet alleen de ALB.
  # Binnen een VPC is dat de enige manier.
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["10.0.2.0/24", "10.0.3.0/24"] # de Hub-publieke subnets waarin de ALB draait
    description = "HTTP vanaf de Application Load Balancer (CIDR van de Hub-publieke subnets; een SG-referentie kan niet cross-VPC)"
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

  egress {
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = ["10.1.0.0/16"]
    description = "DNS naar de VPC-resolver van de eigen VPC (nodig omdat alle overige egress dicht staat)"
  }

  egress {
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = ["10.1.0.0/16"]
    description = "DNS naar de VPC-resolver van de eigen VPC (TCP-fallback voor grote antwoorden)"
  }

  tags = { Name = "web-ecs-sg" }
}

# Database SG (MariaDB) - REQ-NCA-P1-02: geen publiek IP, uitsluitend
# bereikbaar via de Web-spoke.
#
# Het oorspronkelijke ontwerp-document opende poort 9104 "voor
# mysqld_exporter". Die exporter wordt nergens gerenderd en Prometheus scant
# de database niet, dus de regel deed niets. DB-metrieken komen nu uit CloudWatch
# RDS (zie alarms.tf) en het dashboard. De regel is weggehaald omdat een
# security group geen dode poorten hoort te openen - zie TESTPLAN.md (test T5)
# voor de vervolgende aanpak als je er later wél een exporter bij zet.
#
# LET OP - de `description` hieronder is bewust NIET bijgewerkt, hoewel poort
# 9104 er niet meer in staat. `description` is ForceNew in de AWS-provider:
# wijzigen ervan zou de hele security group vervangen, en AWS weigert het
# verwijderen van een SG die aan een ENI hangt (InvalidGroup.InUse). Vervangen
# zou bovendien db_sg.id unknown maken, en daarmee een onbedoelde in-place
# wijziging aan de draaiende RDS-instance veroorzaken (TESTPLAN.md T13.2).
resource "aws_security_group" "db_sg" {
  name        = "db-maria-sg"
  description = "Allow MariaDB from Web spoke only + exporter scraping from mgmt"
  vpc_id      = aws_vpc.spoke_data.id

  # Zelfde verhaal als bij web_sg: spoke_data en spoke_web zijn verschillende
  # VPC's, dus een SG-referentie naar web_sg is niet mogelijk. web_sg zit in
  # 10.1.0.0/16 en laat daar precies 3306 toe; 10.1.0.0/16 is dus de enige
  # werkbare formulering.
  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = ["10.1.0.0/16"] # het CIDR van de Spoke-Web-VPC
    description = "MariaDB vanaf de NGINX-taken in de Spoke-Web-VPC (cross-VPC, dus CIDR i.p.v. SG-referentie)"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "db-maria-sg" }
}

# Management/Bastion SG - Prometheus/Grafana + (optioneel) SSH.
#
# REQ-NCA-P1-02 eist: "Toegang voor beheer gebeurt uitsluitend via een veilige
# VPN-tunnel of Bastion Host." De praktische invulling hier is fail-closed: als
# var.admin_cidr leeg is worden er GEEN ingress-regels aangemaakt en is de
# instance vanaf het internet volledig dicht. Vul je eigen /32 in om de
# dashboards te zien (TESTPLAN.md test T3).
#
# De `description` is om dezelfde reden als bij db_sg bewust ongewijzigd
# (ForceNew => vervanging van een groep die aan een draaiende EC2-instance
# hangt). De werkelijke regels staan in de dynamic-blocks hieronder.
resource "aws_security_group" "mgmt_sg" {
  name        = "mgmt-sg"
  description = "SSH + Grafana/Prometheus UI vanaf admin_cidr; vrije egress voor scraping/CI"
  vpc_id      = aws_vpc.hub.id

  dynamic "ingress" {
    for_each = var.admin_cidr == "" ? [] : [1]
    content {
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = [var.admin_cidr]
      description = "SSH - alleen nodig als je een key pair zet; anders gebruik je SSM Session Manager"
    }
  }

  dynamic "ingress" {
    for_each = var.admin_cidr == "" ? [] : [1]
    content {
      from_port   = 3000
      to_port     = 3000
      protocol    = "tcp"
      cidr_blocks = [var.admin_cidr]
      description = "Grafana UI"
    }
  }

  dynamic "ingress" {
    for_each = var.admin_cidr == "" ? [] : [1]
    content {
      from_port   = 9090
      to_port     = 9090
      protocol    = "tcp"
      cidr_blocks = [var.admin_cidr]
      description = "Prometheus UI - let op: geen authenticatie, vandaar de strikte CIDR"
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "mgmt-sg" }
}
