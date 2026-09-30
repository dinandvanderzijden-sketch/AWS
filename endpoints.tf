# ============================================================
# VPC Interface Endpoints in het Spoke-Web
#
# WAAROM DIT BESTAAT
# De ECS-taken in 10.1.x hebben geen werkende route naar de AWS-API's. Hun
# enige uitgang is: taak -> TGW -> hub-attachment -> NAT Gateway -> internet.
# Die keten faalt: een taak met zelfs een lege task definition blijft 4+
# minuten op PENDING en sterft met "connection issue between the task and
# Amazon CloudWatch" (getest tijdens de eerste apply, zie TESTPLAN.md T13.3).
# De NAT Gateway zelf was gezond, dus het probleem zat in de routering door de
# hub, niet in de NAT.
#
# Met deze endpoints hebben de taken GEEN internetroute meer nodig: al het
# AWS-verkeer loopt via een interface-endpoint binnen de eigen VPC. Dat lost
# het probleem op én is een securitywinst - de taken kunnen dan niet meer het
# internet op, alleen nog de diensten die hier expliciet staan.
#
# KOSTEN (eu-west-1): 4 interface-endpoints ~ $29/maand; de gateway-endpoint
# voor S3 heeft geen uurprijs, wel $0.01/GB data.
# ============================================================

locals {
  # De API's die een taak nodig heeft om op te starten.
  spoke_interface_services = [
    "secretsmanager", # task-definition 'secrets' blok (DB-wachtwoord)
    "logs",           # awslogs-logdriver
    "ecr.api",        # image-manifest ophalen
    "ecr.dkr",        # image-lagen binnenhalen
  ]
}

# Endpoint-ENI's hebben hun eigen security group nodig; de taken mogen er
# alleen op 443 naar toe.
resource "aws_security_group" "spoke_endpoints_sg" {
  name        = "spoke-endpoints-sg"
  description = "HTTPS naar de AWS-interface-endpoints vanuit Spoke-Web"
  vpc_id      = aws_vpc.spoke_web.id

  ingress {
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.web_sg.id]
    description     = "Secret-injectie, log-uploads en image-pulls door ECS-taken"
  }

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["10.1.0.0/16"]
    description = "Antwoordverkeer binnen dezelfde VPC"
  }

  tags = { Name = "spoke-endpoints-sg" }
}

resource "aws_vpc_endpoint" "spoke_interface" {
  for_each = var.enable_spoke_endpoints ? toset(local.spoke_interface_services) : toset([])

  vpc_id              = aws_vpc.spoke_web.id
  service_name        = "com.amazonaws.${var.aws_region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = [aws_subnet.web_private_a.id, aws_subnet.web_private_b.id]
  security_group_ids  = [aws_security_group.spoke_endpoints_sg.id]

  # De provider-default van 10 minuten is hier te krap. Bij de eerste apply
  # bleven alle vier de endpoints na 10 minuten in state 'pending' staan en
  # faalde de apply op de timeout. Bekend gedrag voor interface-endpoints in
  # een VPC met Transit Gateway-attachments; de gateway-endpoint voor S3 werd
  # in hetzelfde plan wél meteen beschikbaar, wat op de interface-specifieke
  # aanlegstap wijst en niet op een fout in de configuratie.
  #
  # LET OP: dit is een ruimer venster, geen bewezen oplossing. Blijven ze na
  # 30 minuten pending, dan is de oorzaak anders (bijvoorbeeld een quota of
  # een service die niet in de betreffende AZ beschikbaar is) - zie
  # TESTPLAN.md T13.3 voor de diagnose-stappen.
  timeouts {
    create = "30m"
    delete = "30m"
  }

  tags = { Name = "spoke-ep-${each.value}" }
}

# ECR slaat de image-lagen op in S3, dus daarvoor is een gateway-endpoint nodig
# (die kost geen uurprijs). Zonder deze haalt ecr.dkr de lagen niet op.
resource "aws_vpc_endpoint" "spoke_s3" {
  count = var.enable_spoke_endpoints ? 1 : 0

  vpc_id            = aws_vpc.spoke_web.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.spoke_web_rt.id]

  tags = { Name = "spoke-ep-s3" }
}

output "spoke_endpoint_services" {
  value       = var.enable_spoke_endpoints ? local.spoke_interface_services : []
  description = "De AWS-diensten die de taken nu via een endpoint bereiken i.p.v. via de NAT Gateway."
}
