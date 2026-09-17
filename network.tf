# =============================================================================
# network.tf — hub-and-spoke topology.
#
# Hub: public ALB plus management instances.
# Spokes: two web VPCs and one database VPC.
# All east-west traffic is routed through the Transit Gateway.
# =============================================================================

resource "aws_vpc" "hub" {
  cidr_block           = var.hub_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.project_name}-hub-vpc" }
}

resource "aws_vpc" "web" {
  count                = 2
  cidr_block           = var.web_vpc_cidrs[count.index]
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.project_name}-web-${count.index + 1}-vpc" }
}

resource "aws_vpc" "database" {
  cidr_block           = var.database_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.project_name}-database-vpc" }
}

resource "aws_internet_gateway" "hub" {
  vpc_id = aws_vpc.hub.id
  tags   = { Name = "${var.project_name}-hub-igw" }
}

resource "aws_internet_gateway" "web" {
  count  = 2
  vpc_id = aws_vpc.web[count.index].id
  tags   = { Name = "${var.project_name}-web-${count.index + 1}-igw" }
}

# --- Hub subnets -------------------------------------------------------------

resource "aws_subnet" "hub_public" {
  count                   = 2
  vpc_id                  = aws_vpc.hub.id
  cidr_block              = var.hub_public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.project_name}-hub-public-${local.azs[count.index]}" }
}

resource "aws_subnet" "hub_private" {
  count             = 2
  vpc_id            = aws_vpc.hub.id
  cidr_block        = var.hub_private_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]
  tags              = { Name = "${var.project_name}-hub-private-${local.azs[count.index]}" }
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
  count          = 2
  subnet_id      = aws_subnet.hub_public[count.index].id
  route_table_id = aws_route_table.hub_public.id
}

resource "aws_eip" "hub_nat" {
  domain = "vpc"
  tags   = { Name = "${var.project_name}-hub-nat-eip" }
}

resource "aws_nat_gateway" "hub" {
  allocation_id = aws_eip.hub_nat.id
  subnet_id     = aws_subnet.hub_public[0].id
  tags          = { Name = "${var.project_name}-hub-nat" }
  depends_on    = [aws_internet_gateway.hub]
}

resource "aws_route_table" "hub_private" {
  vpc_id = aws_vpc.hub.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.hub.id
  }
  tags = { Name = "${var.project_name}-hub-private-rt" }
}

resource "aws_route_table_association" "hub_private" {
  count          = 2
  subnet_id      = aws_subnet.hub_private[count.index].id
  route_table_id = aws_route_table.hub_private.id
}

# --- Web spokes --------------------------------------------------------------

resource "aws_subnet" "web_private" {
  count             = 2
  vpc_id            = aws_vpc.web[count.index].id
  cidr_block        = var.web_private_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]
  tags              = { Name = "${var.project_name}-web-${count.index + 1}-private" }
}

resource "aws_subnet" "web_public" {
  count                   = 2
  vpc_id                  = aws_vpc.web[count.index].id
  cidr_block              = var.web_public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.project_name}-web-${count.index + 1}-public" }
}

resource "aws_eip" "web_nat" {
  count  = 2
  domain = "vpc"
  tags   = { Name = "${var.project_name}-web-${count.index + 1}-nat-eip" }
}

resource "aws_nat_gateway" "web" {
  count         = 2
  allocation_id = aws_eip.web_nat[count.index].id
  subnet_id     = aws_subnet.web_public[count.index].id
  tags          = { Name = "${var.project_name}-web-${count.index + 1}-nat" }
  depends_on    = [aws_internet_gateway.web]
}

resource "aws_route_table" "web_public" {
  count  = 2
  vpc_id = aws_vpc.web[count.index].id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.web[count.index].id
  }
}

resource "aws_route_table_association" "web_public" {
  count          = 2
  subnet_id      = aws_subnet.web_public[count.index].id
  route_table_id = aws_route_table.web_public[count.index].id
}

resource "aws_route_table" "web_private" {
  count  = 2
  vpc_id = aws_vpc.web[count.index].id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.web[count.index].id
  }
}

resource "aws_route_table_association" "web_private" {
  count          = 2
  subnet_id      = aws_subnet.web_private[count.index].id
  route_table_id = aws_route_table.web_private[count.index].id
}

# --- Database spoke ----------------------------------------------------------

resource "aws_subnet" "database_private" {
  count             = 2
  vpc_id            = aws_vpc.database.id
  cidr_block        = var.database_private_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]
  tags              = { Name = "${var.project_name}-database-private-${local.azs[count.index]}" }
}

resource "aws_route_table" "database_private" {
  vpc_id = aws_vpc.database.id
  tags   = { Name = "${var.project_name}-database-private-rt" }
}

resource "aws_route_table_association" "database_private" {
  count          = 2
  subnet_id      = aws_subnet.database_private[count.index].id
  route_table_id = aws_route_table.database_private.id
}

# --- Transit Gateway and VPC routing ----------------------------------------

resource "aws_ec2_transit_gateway" "this" {
  description                     = "${var.project_name} hub and spoke routing"
  default_route_table_association = "disable"
  default_route_table_propagation = "disable"
  tags                            = { Name = "${var.project_name}-tgw" }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "hub" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  vpc_id             = aws_vpc.hub.id
  subnet_ids         = aws_subnet.hub_private[*].id
  tags               = { Name = "${var.project_name}-hub-tgw-attachment" }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "web" {
  count              = 2
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  vpc_id             = aws_vpc.web[count.index].id
  subnet_ids         = [aws_subnet.web_private[count.index].id]
  tags               = { Name = "${var.project_name}-web-${count.index + 1}-tgw-attachment" }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "database" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  vpc_id             = aws_vpc.database.id
  subnet_ids         = aws_subnet.database_private[*].id
  tags               = { Name = "${var.project_name}-database-tgw-attachment" }
}

resource "aws_ec2_transit_gateway_route_table" "this" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  tags               = { Name = "${var.project_name}-tgw-rt" }
}

resource "aws_ec2_transit_gateway_route_table_association" "hub" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.hub.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.this.id
}

resource "aws_ec2_transit_gateway_route_table_association" "web" {
  count                          = 2
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.web[count.index].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.this.id
}

resource "aws_ec2_transit_gateway_route_table_association" "database" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.database.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.this.id
}

resource "aws_ec2_transit_gateway_route" "to_hub" {
  destination_cidr_block         = var.hub_vpc_cidr
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.hub.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.this.id
}

resource "aws_ec2_transit_gateway_route" "to_web" {
  count                          = 2
  destination_cidr_block         = var.web_vpc_cidrs[count.index]
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.web[count.index].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.this.id
}

resource "aws_ec2_transit_gateway_route" "to_database" {
  destination_cidr_block         = var.database_vpc_cidr
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.database.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.this.id
}

resource "aws_route" "hub_to_spokes" {
  for_each               = toset(concat(var.web_vpc_cidrs, [var.database_vpc_cidr]))
  route_table_id         = aws_route_table.hub_private.id
  destination_cidr_block = each.value
  transit_gateway_id     = aws_ec2_transit_gateway.this.id
}

resource "aws_route" "web_to_hub" {
  count                  = 2
  route_table_id         = aws_route_table.web_private[count.index].id
  destination_cidr_block = var.hub_vpc_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.this.id
}

resource "aws_route" "web_to_database" {
  count                  = 2
  route_table_id         = aws_route_table.web_private[count.index].id
  destination_cidr_block = var.database_vpc_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.this.id
}

resource "aws_route" "database_to_web" {
  count                  = 2
  route_table_id         = aws_route_table.database_private.id
  destination_cidr_block = var.web_vpc_cidrs[count.index]
  transit_gateway_id     = aws_ec2_transit_gateway.this.id
}
