
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


# SPOKE 1 VPC - Web 1 (10.1.0.0/16)
resource "aws_vpc" "spoke_web_1" {
  cidr_block           = "10.1.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = "Spoke-Web1-VPC" }
}

resource "aws_subnet" "web1_private_a" {
  vpc_id            = aws_vpc.spoke_web_1.id
  cidr_block        = "10.1.1.0/24"
  availability_zone = "${var.aws_region}a"
  tags              = { Name = "Spoke-Web1-Private-A" }
}

# SPOKE 2 VPC - Web 2 (10.2.0.0/16)
resource "aws_vpc" "spoke_web_2" {
  cidr_block           = "10.2.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = "Spoke-Web2-VPC" }
}

resource "aws_subnet" "web2_private_b" {
  vpc_id            = aws_vpc.spoke_web_2.id
  cidr_block        = "10.2.1.0/24"
  availability_zone = "${var.aws_region}b"
  tags              = { Name = "Spoke-Web2-Private-B" }
}

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


resource "aws_vpc_peering_connection" "hub_to_web" {
  vpc_id      = aws_vpc.hub.id
  peer_vpc_id = aws_vpc.spoke_web.id
  auto_accept = true
  tags        = { Name = "Peering-Hub-Web" }
}
# VPC PEERING (Hub <-> Spoke Web 2)
resource "aws_vpc_peering_connection" "hub_to_web2" {
  vpc_id      = aws_vpc.hub.id
  peer_vpc_id = aws_vpc.spoke_web_2.id
  auto_accept = true
  tags        = { Name = "Peering-Hub-Web2" }
}
resource "aws_vpc_peering_connection" "web2_to_data" {
  vpc_id      = aws_vpc.spoke_web.id
  peer_vpc_id = aws_vpc.spoke_data.id
  auto_accept = true
  tags        = { Name = "Peering-Web-Data" }
}
resource "aws_vpc_peering_connection" "web_to_data" {
  vpc_id      = aws_vpc.spoke_web.id
  peer_vpc_id = aws_vpc.spoke_data.id
  auto_accept = true
  tags        = { Name = "Peering-Web-Data" }
}