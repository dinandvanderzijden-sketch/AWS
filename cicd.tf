# =============================================================================
# cicd.tf — self-hosted GitHub Actions runner op EC2.
#
# Staat in een publieke subnet (net als de andere management-VM), maar is
# alleen bereikbaar op SSH vanaf admin_cidr (zie security.tf) — hij heeft
# zelf alleen uitgaand internet nodig om zich bij GitHub te melden, er hoeft
# nooit een poort open voor inkomend verkeer vanaf internet.
# =============================================================================

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "runner" {
  name               = "${var.project_name}-runner-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

# LET OP: breed van opzet omdat de pipeline zélf de volledige infrastructuur
# beheert. Bouw dit in een vervolgstap af naar een strakker afgebakende
# policy per resourcetype als dit richting een echte productieomgeving gaat.
resource "aws_iam_role_policy_attachment" "runner_admin" {
  role       = aws_iam_role.runner.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_instance_profile" "runner" {
  name = "${var.project_name}-runner-profile"
  role = aws_iam_role.runner.name
}

resource "aws_instance" "runner" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.runner_instance_type
  subnet_id                   = aws_subnet.public[0].id
  vpc_security_group_ids      = [aws_security_group.management.id]
  iam_instance_profile        = aws_iam_instance_profile.runner.name
  key_name                    = var.key_pair_name
  associate_public_ip_address = true

  user_data = templatefile("${path.module}/templates/runner-userdata.sh.tpl", {
    github_org    = var.github_org
    github_repo   = var.github_repo
    runner_token  = var.github_runner_token
    runner_labels = "self-hosted,aws,${var.project_name}"
  })

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  tags = { Name = "${var.project_name}-gh-runner" }
}
