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

# Web Server (ECS Containers) Security Group
resource "aws_security_group" "web_sg" {
  name        = "web-ecs-sg"
  description = "Allow HTTP from ALB"
  vpc_id      = aws_vpc.spoke_web.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["10.0.2.0/24", "10.0.3.0/24"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
# Web Server (ECS Containers) Security Group
resource "aws_security_group" "web_sg" {
  name        = "web-ecs-sg"
  description = "Allow HTTP from ALB"
  vpc_id      = aws_vpc.spoke_web2.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["10.0.2.0/24", "10.0.3.0/24"]
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