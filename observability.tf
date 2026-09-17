# =============================================================================
# observability.tf — Prometheus + Grafana op één EC2-instance.
# =============================================================================

resource "aws_instance" "observability" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t3.medium"
  subnet_id                   = aws_subnet.hub_public[1].id
  vpc_security_group_ids      = [aws_security_group.management.id]
  key_name                    = var.key_pair_name
  associate_public_ip_address = true

  user_data = file("${path.module}/templates/observability-userdata.sh.tpl")

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  tags = { Name = "${var.project_name}-observability" }
}
