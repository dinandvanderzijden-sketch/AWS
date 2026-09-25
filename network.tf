# ============================================================
# HUB VPC (10.0.0.0/16)
# ============================================================
resource "aws_vpc" "hub" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = "Hub-VPC" }
}

resource "aws_internet_gateway" "hub_igw" {
  vpc_id = aws_vpc.hub.id
  tags   = { Name = "Hub-IGW" }
}

resource "aws_subnet" "hub_public_a" {
  vpc_id                  = aws_vpc.hub.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true
  tags                    = { Name = "Hub-Public-Subnet-A" }
}

resource "aws_subnet" "hub_public_b" {
  vpc_id                  = aws_vpc.hub.id
  cidr_block              = "10.0.3.0/24"
  availability_zone       = "${var.aws_region}b"
  map_public_ip_on_launch = true
  tags                    = { Name = "Hub-Public-Subnet-B" }
}

resource "aws_subnet" "hub_mgmt" {
  vpc_id            = aws_vpc.hub.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "${var.aws_region}a"
  tags              = { Name = "Hub-Mgmt-Subnet" }
}

# --- NAT Gateway: geeft de private/mgmt subnets uitgaand internet (ECR pulls, patches, CI/CD) ---
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "Hub-NAT-EIP" }
}

resource "aws_nat_gateway" "hub_nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.hub_public_a.id
  tags          = { Name = "Hub-NAT-GW" }
  depends_on    = [aws_internet_gateway.hub_igw]
}

# --- Route tables: Hub ---
resource "aws_route_table" "hub_public_rt" {
  vpc_id = aws_vpc.hub.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.hub_igw.id
  }
  tags = { Name = "Hub-Public-RT" }
}

resource "aws_route_table_association" "pub_a" {
  subnet_id      = aws_subnet.hub_public_a.id
  route_table_id = aws_route_table.hub_public_rt.id
}

resource "aws_route_table_association" "pub_b" {
  subnet_id      = aws_subnet.hub_public_b.id
  route_table_id = aws_route_table.hub_public_rt.id
}

resource "aws_route_table" "hub_mgmt_rt" {
  vpc_id = aws_vpc.hub.id

  # Internet (patches, docker pulls) via de NAT Gateway
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.hub_nat.id
  }
  # Naar de web-spoke (nginx-exporter scraping) via Transit Gateway
  route {
    cidr_block         = "10.1.0.0/16"
    transit_gateway_id = aws_ec2_transit_gateway.hub_tgw.id
  }
  # Naar de data-spoke (db-exporter scraping) via Transit Gateway
  route {
    cidr_block         = "10.3.0.0/16"
    transit_gateway_id = aws_ec2_transit_gateway.hub_tgw.id
  }

  tags       = { Name = "Hub-Mgmt-RT" }
  depends_on = [aws_ec2_transit_gateway_vpc_attachment.hub]
}

resource "aws_route_table_association" "mgmt" {
  subnet_id      = aws_subnet.hub_mgmt.id
  route_table_id = aws_route_table.hub_mgmt_rt.id
}

# ============================================================
# SPOKE-WEB VPC (10.1.0.0/16) - NGINX/ECS Fargate over 2 AZ's
# (dit is de 2-AZ HA-laag; zie de toelichting in de projectsamenvatting
#  over waarom dit 1 VPC met 2 subnets is i.p.v. 2 losse spoke-VPC's)
# ============================================================
resource "aws_vpc" "spoke_web" {
  cidr_block           = "10.1.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = "Spoke-Web-VPC" }
}

resource "aws_subnet" "web_private_a" {
  vpc_id            = aws_vpc.spoke_web.id
  cidr_block        = "10.1.1.0/24"
  availability_zone = "${var.aws_region}a"
  tags              = { Name = "Spoke-Web-Private-A" }
}

resource "aws_subnet" "web_private_b" {
  vpc_id            = aws_vpc.spoke_web.id
  cidr_block        = "10.1.2.0/24"
  availability_zone = "${var.aws_region}b"
  tags              = { Name = "Spoke-Web-Private-B" }
}

resource "aws_route_table" "spoke_web_rt" {
  vpc_id = aws_vpc.spoke_web.id
  route {
    cidr_block         = "0.0.0.0/0"
    transit_gateway_id = aws_ec2_transit_gateway.hub_tgw.id
  }
  tags       = { Name = "Spoke-Web-RT" }
  depends_on = [aws_ec2_transit_gateway_vpc_attachment.spoke_web]
}

resource "aws_route_table_association" "web_a" {
  subnet_id      = aws_subnet.web_private_a.id
  route_table_id = aws_route_table.spoke_web_rt.id
}

resource "aws_route_table_association" "web_b" {
  subnet_id      = aws_subnet.web_private_b.id
  route_table_id = aws_route_table.spoke_web_rt.id
}

# ============================================================
# SPOKE-DATA VPC (10.3.0.0/16) - RDS MariaDB, Multi-AZ
# ============================================================
resource "aws_vpc" "spoke_data" {
  cidr_block           = "10.3.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = "Spoke-Data-VPC" }
}

resource "aws_subnet" "data_private_a" {
  vpc_id            = aws_vpc.spoke_data.id
  cidr_block        = "10.3.1.0/24"
  availability_zone = "${var.aws_region}a"
  tags              = { Name = "Spoke-Data-Private-A" }
}

resource "aws_subnet" "data_private_b" {
  vpc_id            = aws_vpc.spoke_data.id
  cidr_block        = "10.3.2.0/24"
  availability_zone = "${var.aws_region}b"
  tags              = { Name = "Spoke-Data-Private-B" }
}

resource "aws_route_table" "spoke_data_rt" {
  vpc_id = aws_vpc.spoke_data.id
  # Alleen terug naar web (db-antwoorden) en hub (exporter scraping) - bewust GEEN
  # internetroute, zodat de database-laag geïsoleerd blijft (REQ-NCA-P1-02).
  route {
    cidr_block         = "10.1.0.0/16"
    transit_gateway_id = aws_ec2_transit_gateway.hub_tgw.id
  }
  route {
    cidr_block         = "10.0.0.0/16"
    transit_gateway_id = aws_ec2_transit_gateway.hub_tgw.id
  }
  tags       = { Name = "Spoke-Data-RT" }
  depends_on = [aws_ec2_transit_gateway_vpc_attachment.spoke_data]
}

resource "aws_route_table_association" "data_a" {
  subnet_id      = aws_subnet.data_private_a.id
  route_table_id = aws_route_table.spoke_data_rt.id
}

resource "aws_route_table_association" "data_b" {
  subnet_id      = aws_subnet.data_private_b.id
  route_table_id = aws_route_table.spoke_data_rt.id
}

# ============================================================
# TRANSIT GATEWAY - dit ís het Hub-and-Spoke netwerk (vervangt de
# losse VPC-peerings van de vorige versie, die geen routes hadden)
# ============================================================
resource "aws_ec2_transit_gateway" "hub_tgw" {
  description                     = "Hub-and-Spoke TGW - Hub, Spoke-Web, Spoke-Data"
  default_route_table_association = "enable"
  default_route_table_propagation = "enable"
  tags                             = { Name = "Hub-TGW" }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "hub" {
  transit_gateway_id = aws_ec2_transit_gateway.hub_tgw.id
  vpc_id              = aws_vpc.hub.id
  subnet_ids          = [aws_subnet.hub_mgmt.id]
  tags                = { Name = "TGW-Attach-Hub" }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "spoke_web" {
  transit_gateway_id = aws_ec2_transit_gateway.hub_tgw.id
  vpc_id              = aws_vpc.spoke_web.id
  subnet_ids          = [aws_subnet.web_private_a.id, aws_subnet.web_private_b.id]
  tags                = { Name = "TGW-Attach-Spoke-Web" }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "spoke_data" {
  transit_gateway_id = aws_ec2_transit_gateway.hub_tgw.id
  vpc_id              = aws_vpc.spoke_data.id
  subnet_ids          = [aws_subnet.data_private_a.id, aws_subnet.data_private_b.id]
  tags                = { Name = "TGW-Attach-Spoke-Data" }
}

# Default-route (internet) op de TGW zelf: al het niet-specifieke verkeer vanaf de
# spokes gaat naar de Hub-attachment, die het via de NAT Gateway naar buiten stuurt.
resource "aws_ec2_transit_gateway_route" "default_via_hub" {
  destination_cidr_block         = "0.0.0.0/0"
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.hub.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway.hub_tgw.association_default_route_table_id
}
