# ============================================================
# VPC Interface Endpoints in het Spoke-Web
#
# WAAROM DIT BESTAAT
# De ECS-taken in 10.1.x hebben geen werkende route naar de AWS-API's. Hun
# enige uitgang is: taak -> TGW -> hub-attachment (10.0.1.0/24) -> NAT
# Gateway (10.0.2.0/24) -> internet. Die keten faalt: een taak met zelfs een
# lege task definition blijft 4+ minuten op PENDING en sterft met
# "connection issue between the task and Amazon CloudWatch".
# De NAT Gateway zelf is gezond (ErrorPortAllocation = 0, stabiele
# ActiveConnectionCount), dus het probleem zit in de route/retour-route
# door de hub, niet in de NAT.
#
# Met deze endpoints hebben de taken GEEN internetroute meer nodig: al het
# AWS-verkeer loopt via een interface-endpoint binnen de eigen VPC. Dat lost
# het probleem op én is tegelijk een securitywinst - de taken kunnen dan niet
# meer het internet op, alleen nog de diensten die hier expliciet staan.
#
# KOSTEN (eu-west-1, per uur, ongeveer):
#   4 interface-endpoints  ~ $0.04/uur  ~ $29/maand
#   1 gateway-endpoint     geen uurprijs, wel $0.01/GB data
# Zet enable_spoke_endpoints op false om ze weer te verwijderen; dan
# verwijdert Terraform ze weer.
# ============================================================

variable "enable_spoke_endpoints" {
  description = "Maak VPC-endpoints aan in het Spoke-Web zodat de ECS-taken de AWS-API's bereiken zonder via de NAT Gateway te lopen."
  type        = bool
  default     = true
}

locals {
  # Interface-endpoints voor de API's die een taak nodig heeft om op te starten.
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
