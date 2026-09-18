# Load Balancer Security Group (Publiek HTTP/HTTPS)
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

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Security Group voor Spoke 1 Web
resource "aws_security_group" "web1_sg" {
  name        = "web1-ecs-sg"
  description = "Allow HTTP from ALB to Spoke 1"
  vpc_id      = aws_vpc.spoke_web_1.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["10.0.2.0/24", "10.0.3.0/24"] # Vanuit Hub ALB
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Security Group voor Spoke 2 Web
resource "aws_security_group" "web2_sg" {
  name        = "web2-ecs-sg"
  description = "Allow HTTP from ALB to Spoke 2"
  vpc_id      = aws_vpc.spoke_web_2.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["10.0.2.0/24", "10.0.3.0/24"] # Vanuit Hub ALB
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Database Security Group (REQ-NCA-P1-02: Geen publiek IP, uitsluitend bereikbaar via Spoke Web)
resource "aws_security_group" "db_sg" {
  name        = "db-maria-sg"
  description = "Allow MySQL/MariaDB from Web Spoke only"
  vpc_id      = aws_vpc.spoke_data.id

  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = ["10.1.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}