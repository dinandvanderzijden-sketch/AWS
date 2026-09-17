# =============================================================================
# network.tf — één VPC, drie lagen subnets, over 2 AZ's.
#
#   Publiek         → ALB + NAT Gateway
#   Privé-web       → ECS Fargate (NGINX)
#   Privé-data      → RDS MariaDB
#
# Alles in dezelfde VPC = geen Transit Gateway, geen cross-VPC gedoe met
# security groups of load balancer targets. Voor een opdracht van deze
# omvang is dit ruim voldoende segmentatie (REQ-NCA-P1-01) en veel
# makkelijker te volgen dan een hub-and-spoke opzet met meerdere VPC's.
# =============================================================================

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.project_name}-vpc" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.project_name}-igw" }
}

# --- Publieke subnets (ALB, NAT Gateway) ------------------------------------

resource "aws_subnet" "public" {
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.project_name}-public-${local.azs[count.index]}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = { Name = "${var.project_name}-public-rt" }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Eén NAT Gateway (bewust single-AZ, i.v.m. kosten — zie README).
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.project_name}-nat-eip" }
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags          = { Name = "${var.project_name}-nat" }
  depends_on    = [aws_internet_gateway.this]
}

# --- Privé subnets: web (ECS) en data (RDS) delen dezelfde route table -----
# (allebei alleen uitgaand internet nodig, via de NAT Gateway)

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }
  tags = { Name = "${var.project_name}-private-rt" }
}

resource "aws_subnet" "private_web" {
  count             = length(var.private_web_subnet_cidrs)
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_web_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]
  tags              = { Name = "${var.project_name}-private-web-${local.azs[count.index]}" }
}

resource "aws_route_table_association" "private_web" {
  count          = length(aws_subnet.private_web)
  subnet_id      = aws_subnet.private_web[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_subnet" "private_db" {
  count             = length(var.private_db_subnet_cidrs)
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_db_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]
  tags              = { Name = "${var.project_name}-private-db-${local.azs[count.index]}" }
}

resource "aws_route_table_association" "private_db" {
  count          = length(aws_subnet.private_db)
  subnet_id      = aws_subnet.private_db[count.index].id
  route_table_id = aws_route_table.private.id
}
