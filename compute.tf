# =============================================================================
# compute.tf — publieke ALB in de hub met één NGINX-server per web-spoke.
# =============================================================================

resource "aws_lb" "this" {
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.hub_public[*].id

  tags = { Name = "${var.project_name}-alb" }
}

resource "aws_lb_target_group" "this" {
  name        = "${var.project_name}-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.hub.id
  target_type = "ip"

  health_check {
    path                = "/"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 15
    timeout             = 5
  }

  tags = { Name = "${var.project_name}-tg" }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}

resource "aws_instance" "nginx" {
  count                       = 2
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.web_instance_type
  subnet_id                   = aws_subnet.web_private[count.index].id
  vpc_security_group_ids      = [aws_security_group.web[count.index].id]
  associate_public_ip_address = false
  user_data                   = file("${path.module}/templates/nginx-userdata.sh.tpl")

  root_block_device {
    volume_size = 10
    volume_type = "gp3"
    encrypted   = true
  }

  tags = { Name = "${var.project_name}-nginx-${count.index + 1}" }
}

resource "aws_lb_target_group_attachment" "nginx" {
  count            = 2
  target_group_arn = aws_lb_target_group.this.arn
  target_id        = aws_instance.nginx[count.index].private_ip
  port             = 80
}
