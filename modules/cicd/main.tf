# =============================================================================
# CI/CD MODULE — Self-hosted GitHub Actions runner op EC2 in de Hub
# management subnet. REQ-NCA-P1-07/08.
#
# De runner heeft GEEN AWS access keys nodig: rechten lopen via een IAM
# Instance Profile (EC2 IAM Role), zoals in het analysedocument beschreven.
# =============================================================================

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

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

# LET OP: dit project geeft de runner brede rechten omdat de pipeline zelf
# de volledige infrastructuur (VPCs, ECS, RDS, IAM-rollen, ...) beheert.
# Vervang dit in een echte productieomgeving door een strak afgebakende
# policy per resourcetype, of splits de runner op in losse rollen per stage.
resource "aws_iam_role_policy_attachment" "runner_admin" {
  role       = aws_iam_role.runner.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_instance_profile" "runner" {
  name = "${var.project_name}-runner-profile"
  role = aws_iam_role.runner.name
}

resource "aws_instance" "runner" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.runner_instance_type
  subnet_id              = var.hub_mgmt_subnet_id
  vpc_security_group_ids = [var.management_sg_id]
  iam_instance_profile   = aws_iam_instance_profile.runner.name
  key_name               = var.key_pair_name

  # Registratietoken komt uit een sensitive variable (zie variables.tf) —
  # nooit hardcoded, en met korte levensduur (GitHub genereert 'm on-demand).
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
