# =============================================================================
# NETWORK MODULE — Hub-and-Spoke topologie (REQ-NCA-P1-01)
#
# Hub VPC        : ALB (publiek) + NAT Gateway + Management subnet
# Spoke Web VPC  : private subnets voor NGINX/ECS Fargate, 2 AZ's
# Spoke Data VPC : private subnets voor RDS MariaDB, 2 AZ's
#
# Alles wordt met elkaar verbonden via een Transit Gateway, zodat een nieuwe
# spoke later zonder herstructurering van het bestaande netwerk kan worden
# toegevoegd (acceptatiecriterium REQ-NCA-P1-01).
# =============================================================================

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

data "aws_availability_zones" "available" {
  state = "available"
}

# ---------------------------------------------------------------------------
# HUB VPC
# ---------------------------------------------------------------------------

resource "aws_vpc" "hub" {
  cidr_block           = var.hub_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.project_name}-hub-vpc" }
}

resource "aws_internet_gateway" "hub" {
  vpc_id = aws_vpc.hub.id
  tags   = { Name = "${var.project_name}-hub-igw" }
}

resource "aws_subnet" "hub_public" {
  count                   = length(var.hub_public_subnet_cidrs)
  vpc_id                  = aws_vpc.hub.id
  cidr_block              = var.hub_public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.project_name}-hub-public-${local.azs[count.index]}" }
}

resource "aws_subnet" "hub_mgmt" {
  vpc_id                  = aws_vpc.hub.id
  cidr_block               = var.hub_mgmt_subnet_cidr
  availability_zone        = local.azs[0]
  map_public_ip_on_launch  = false
  tags                     = { Name = "${var.project_name}-hub-mgmt" }
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.project_name}-nat-eip" }
}

# NAT Gateway staat in de publieke subnet en biedt uitgaande internettoegang
# aan zowel de management subnet als (via de Transit Gateway) de spokes.
resource "aws_nat_gateway" "hub" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.hub_public[0].id
  tags          = { Name = "${var.project_name}-hub-nat" }
  depends_on    = [aws_internet_gateway.hub]
}

resource "aws_route_table" "hub_public" {
  vpc_id = aws_vpc.hub.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.hub.id
  }
  tags = { Name = "${var.project_name}-hub-public-rt" }
}

resource "aws_route_table_association" "hub_public" {
  count          = length(aws_subnet.hub_public)
  subnet_id      = aws_subnet.hub_public[count.index].id
  route_table_id = aws_route_table.hub_public.id
}

resource "aws_route_table" "hub_mgmt" {
  vpc_id = aws_vpc.hub.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.hub.id
  }
  tags = { Name = "${var.project_name}-hub-mgmt-rt" }
}

resource "aws_route_table_association" "hub_mgmt" {
  subnet_id      = aws_subnet.hub_mgmt.id
  route_table_id = aws_route_table.hub_mgmt.id
}

# ---------------------------------------------------------------------------
# SPOKE 1: WEB (NGINX / ECS Fargate) — REQ-NCA-P1-04, 2 AZ's
# ---------------------------------------------------------------------------

resource "aws_vpc" "spoke_web" {
  cidr_block           = var.spoke_web_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.project_name}-spoke-web-vpc" }
}

resource "aws_subnet" "spoke_web" {
  count             = length(var.spoke_web_subnet_cidrs)
  vpc_id            = aws_vpc.spoke_web.id
  cidr_block        = var.spoke_web_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]
  tags              = { Name = "${var.project_name}-spoke-web-${local.azs[count.index]}" }
}

# ---------------------------------------------------------------------------
# SPOKE 2: DATA (RDS MariaDB) — Multi-AZ
# ---------------------------------------------------------------------------

resource "aws_vpc" "spoke_data" {
  cidr_block           = var.spoke_data_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.project_name}-spoke-data-vpc" }
}

resource "aws_subnet" "spoke_data" {
  count             = length(var.spoke_data_subnet_cidrs)
  vpc_id            = aws_vpc.spoke_data.id
  cidr_block        = var.spoke_data_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]
  tags              = { Name = "${var.project_name}-spoke-data-${local.azs[count.index]}" }
}

# ---------------------------------------------------------------------------
# TRANSIT GATEWAY — verbindt Hub met beide Spokes (uitbreidbaar, REQ-NCA-P1-01)
# ---------------------------------------------------------------------------

resource "aws_ec2_transit_gateway" "hub" {
  description                    = "${var.project_name} hub-and-spoke transit gateway"
  default_route_table_association = "disable"
  default_route_table_propagation = "disable"
  tags                            = { Name = "${var.project_name}-tgw" }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "hub" {
  transit_gateway_id = aws_ec2_transit_gateway.hub.id
  vpc_id              = aws_vpc.hub.id
  subnet_ids          = [aws_subnet.hub_mgmt.id]
  tags                = { Name = "${var.project_name}-tgw-attach-hub" }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "spoke_web" {
  transit_gateway_id = aws_ec2_transit_gateway.hub.id
  vpc_id              = aws_vpc.spoke_web.id
  subnet_ids          = aws_subnet.spoke_web[*].id
  tags                = { Name = "${var.project_name}-tgw-attach-spoke-web" }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "spoke_data" {
  transit_gateway_id = aws_ec2_transit_gateway.hub.id
  vpc_id              = aws_vpc.spoke_data.id
  subnet_ids          = aws_subnet.spoke_data[*].id
  tags                = { Name = "${var.project_name}-tgw-attach-spoke-data" }
}

# Eén gedeelde TGW route table: alle attachments propageren naar elkaar.
# Nieuwe spokes hoeven alleen een attachment + route toe te voegen — geen
# wijziging aan bestaande VPCs nodig (REQ-NCA-P1-01 acceptatiecriterium).
resource "aws_ec2_transit_gateway_route_table" "hub" {
  transit_gateway_id = aws_ec2_transit_gateway.hub.id
  tags                = { Name = "${var.project_name}-tgw-rt" }
}

resource "aws_ec2_transit_gateway_route_table_association" "hub" {
  transit_gateway_attachment_id = aws_ec2_transit_gateway_vpc_attachment.hub.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.hub.id
}

resource "aws_ec2_transit_gateway_route_table_association" "spoke_web" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.spoke_web.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.hub.id
}

resource "aws_ec2_transit_gateway_route_table_association" "spoke_data" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.spoke_data.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.hub.id
}

resource "aws_ec2_transit_gateway_route_table_propagation" "hub" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.hub.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.hub.id
}

resource "aws_ec2_transit_gateway_route_table_propagation" "spoke_web" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.spoke_web.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.hub.id
}

resource "aws_ec2_transit_gateway_route_table_propagation" "spoke_data" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.spoke_data.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.hub.id
}

# Routes: elke VPC krijgt een route naar de andere VPC-CIDR's via de TGW.

resource "aws_route" "hub_mgmt_to_spoke_web" {
  route_table_id         = aws_route_table.hub_mgmt.id
  destination_cidr_block = var.spoke_web_vpc_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.hub.id
  depends_on              = [aws_ec2_transit_gateway_vpc_attachment.hub]
}

resource "aws_route" "hub_mgmt_to_spoke_data" {
  route_table_id         = aws_route_table.hub_mgmt.id
  destination_cidr_block = var.spoke_data_vpc_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.hub.id
  depends_on              = [aws_ec2_transit_gateway_vpc_attachment.hub]
}

resource "aws_route" "hub_public_to_spoke_web" {
  route_table_id         = aws_route_table.hub_public.id
  destination_cidr_block = var.spoke_web_vpc_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.hub.id
  depends_on              = [aws_ec2_transit_gateway_vpc_attachment.hub]
}

resource "aws_route_table" "spoke_web" {
  vpc_id = aws_vpc.spoke_web.id
  route {
    cidr_block         = var.hub_vpc_cidr
    transit_gateway_id = aws_ec2_transit_gateway.hub.id
  }
  route {
    cidr_block         = var.spoke_data_vpc_cidr
    transit_gateway_id = aws_ec2_transit_gateway.hub.id
  }
  # Internet-egress (bijv. ECR image pulls) loopt via de Hub NAT Gateway.
  route {
    cidr_block         = "0.0.0.0/0"
    transit_gateway_id = aws_ec2_transit_gateway.hub.id
  }
  tags       = { Name = "${var.project_name}-spoke-web-rt" }
  depends_on = [aws_ec2_transit_gateway_vpc_attachment.spoke_web]
}

resource "aws_route_table_association" "spoke_web" {
  count          = length(aws_subnet.spoke_web)
  subnet_id      = aws_subnet.spoke_web[count.index].id
  route_table_id = aws_route_table.spoke_web.id
}

resource "aws_route_table" "spoke_data" {
  vpc_id = aws_vpc.spoke_data.id
  route {
    cidr_block         = var.hub_vpc_cidr
    transit_gateway_id = aws_ec2_transit_gateway.hub.id
  }
  route {
    cidr_block         = var.spoke_web_vpc_cidr
    transit_gateway_id = aws_ec2_transit_gateway.hub.id
  }
  # Bewust GEEN 0.0.0.0/0 route: de dataspoke heeft geen internet-egress
  # nodig en dit voorkomt per ongeluk publiek bereikbare paden (REQ-NCA-P1-02).
  tags       = { Name = "${var.project_name}-spoke-data-rt" }
  depends_on = [aws_ec2_transit_gateway_vpc_attachment.spoke_data]
}

resource "aws_route_table_association" "spoke_data" {
  count          = length(aws_subnet.spoke_data)
  subnet_id      = aws_subnet.spoke_data[count.index].id
  route_table_id = aws_route_table.spoke_data.id
}
