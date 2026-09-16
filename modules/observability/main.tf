# =============================================================================
# OBSERVABILITY MODULE — Prometheus + Grafana in de Hub management subnet.
# REQ-NCA-P1-05.
# =============================================================================

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

resource "aws_instance" "observability" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t3.medium"
  subnet_id              = var.hub_mgmt_subnet_id
  vpc_security_group_ids = [var.management_sg_id]
  key_name               = var.key_pair_name

  user_data = templatefile("${path.module}/templates/observability-userdata.sh.tpl", {
    spoke_web_cidr  = var.spoke_web_vpc_cidr
    spoke_data_cidr = var.spoke_data_vpc_cidr
  })

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  tags = { Name = "${var.project_name}-observability" }
}
