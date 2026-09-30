# ============================================================
# ZELF-GEHOSTE GITHUB ACTIONS RUNNER - REQ-NCA-P1-07
#
# WAAROM DIT STANDAARD UIT STAAT
# De actieve workflow (.github/workflows/deploy.yml) draait op
# 'runs-on: ubuntu-latest', dus GitHub-gehost. Dat is een bewuste
# volgordekeuze, geen oversight:
#
#   1. Een workflow die naar een self-hosted runner wijst en die runner is nog
#      niet geregistreerd, blijft HANGEN op "Waiting for a runner". De hele
#      uitrol ligt dan stil, inclusief het apply van de Terraform die de
#      runner zelf moet aanmaken.
#   2. Registratie vereist een GitHub-registration-token (een geheim met ~1 uur
#      geldigheid). Dat is iets wat een mens één keer moet doen.
#   3. De eerste job op de runner is 'terraform init', dus de runner moet in
#      het management-subnet wel uit het internet kunnen naar de AWS-API's.
#
# De infrastructuur hieronder is er dus volledig als IaC, maar uitgeschakeld
# tot je hem activeert. TESTPLAN.md test T7 beschrijft de inschakelstappen in
# de juiste volgorde.
#
# WAT EEN SELF-HOSTED RUNNER OPLOOST
#   - de uitvoerende machine zit binnen de VPC en bereikt de ALB, RDS en de
#     VPC-endpoints op interne IP-adressen, zonder dat daarvoor poorten naar
#     het internet open hoeven
#   - de IAM-rol van de EC2 bepaalt wat er vanuit die machine mag gebeuren:
#     scheiding van rechten op machine- én op pipelineniveau
#   - minder kosten: geen GitHub-minuten
#
# LET OP bij het overstappen: de huidige pipeline logt in met AWS-sleutels uit
# GitHub Secrets (zie deploy.yml). Zet je 'runs-on' om, dan heb je óf de
# instance-profielrol hieronder nodig (dus: geef 'iam:PassRole' aan de
# CI-gebruiker), óf dezelfde keys als secrets.
# ============================================================

locals {
  runner_enabled = var.enable_self_hosted_runner
  runner_name    = "nca-runner-1"

  # De runner-versie waarmee de GitHub Actions-runner is gedownload. Pin hem,
  # net als de Docker-images in monitoring.tf: een floating 'latest' maakt een
  # re-run van dezelfde commit niet reproduceerbaar.
  runner_version = "2.328.0"
}

# ------------------------------------------------------------
# IAM: leesrechten voor CloudWatch, SSM voor beheer zonder open
# poort, en CloudWatch Logs voor de runner-output.
# ------------------------------------------------------------
resource "aws_iam_role" "runner" {
  count = local.runner_enabled ? 1 : 0

  name = "nca-github-runner-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "runner_cloudwatch" {
  count = local.runner_enabled ? 1 : 0

  role       = aws_iam_role.runner[0].name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess"
}

resource "aws_iam_role_policy_attachment" "runner_ssm" {
  count = local.runner_enabled ? 1 : 0

  role       = aws_iam_role.runner[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

locals {
  runner_logs_json = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "PutRunnerLogs"
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogStreams",
      ]
      Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/github-actions-runner*"
    }]
  })
}

resource "aws_iam_role_policy" "runner_logs" {
  count = local.runner_enabled ? 1 : 0

  name   = "nca-runner-put-logs"
  role   = aws_iam_role.runner[0].name
  policy = local.runner_logs_json
}

resource "aws_iam_instance_profile" "runner" {
  count = local.runner_enabled ? 1 : 0

  name = "nca-github-runner-profile"
  role = aws_iam_role.runner[0].name
}

# ------------------------------------------------------------
# De runner-host zelf
#
# Management Subnet (10.0.1.0/24): geen public IP, geen internetroute naar
# buiten behalve via de NAT Gateway in de hub - precies de "eigen
# netwerkgrenzen" die de requirement bedoelt. Inloggen kan alleen via SSM
# Session Manager, dus er hoeft geen enkele poort open.
# ------------------------------------------------------------
resource "aws_instance" "runner" {
  count = local.runner_enabled ? 1 : 0

  ami                         = data.aws_ami.al2023.id
  instance_type               = "t3.small" # Docker + Terraform + de runner zelf
  subnet_id                   = aws_subnet.hub_mgmt.id
  vpc_security_group_ids      = [aws_security_group.mgmt_sg.id]
  iam_instance_profile        = aws_iam_instance_profile.runner[0].name
  associate_public_ip_address = false

  # De user-data installeert de runner en registreert hem, maar alleen als er
  # een registration-token beschikbaar is. Zonder token wordt de runner
  # geïnstalleerd maar niet geregistreerd: de machine is er, de pipeline loopt
  # er nog niet op. Dat is beter dan een apply die halverwege faalt.
  #
  # NB: in een Terraform-heredoc moet elke bash-interpolatie met een extra $
  # worden geschreven ($${VAR}), anders probeert Terraform ${VAR} zelf als een
  # verwijzing naar een resource te lezen en faalt de validatie.
  user_data = <<-EOF
    #!/bin/bash
    set -euo pipefail

    dnf install -y docker git jq
    systemctl enable --now docker
    usermod -aG docker ec2-user

    RUNNER_HOME=/opt/actions-runner
    RUNNER_VERSION="${local.runner_version}"
    RUNNER_DIR="$${RUNNER_HOME}-runner"

    if [ ! -x "$${RUNNER_DIR}/config.sh" ]; then
      mkdir -p "$${RUNNER_HOME}"
      cd "$${RUNNER_HOME}"
      curl -fsSL -o runner.tar.gz \
        "https://github.com/actions/runner/releases/download/v$${RUNNER_VERSION}/actions-runner-linux-x64-$${RUNNER_VERSION}.tar.gz"
      tar xzf runner.tar.gz
      rm runner.tar.gz
      mv actions-runner "$${RUNNER_DIR}"
    fi

    # Registratietoken komt uit SSM Parameter Store, gezet door een mens:
    #   aws ssm put-parameter --name /github-actions/runner/registration-token \
    #     --value <TOKEN> --type SecureString
    REG_TOKEN=$(aws ssm get-parameter \
      --name /github-actions/runner/registration-token \
      --with-decryption --query 'Parameter.Value' --output text 2>/dev/null || echo "")

    if [ -n "$${REG_TOKEN}" ]; then
      cd "$${RUNNER_DIR}"
      # --replace maakt dit idempotent: een al geregistreerde runner wordt
      # eerst verwijderd, anders faalt config.sh met "runner already exists".
      ./config.sh --unattended \
        --url "https://github.com/${var.github_repo}" \
        --token "$${REG_TOKEN}" \
        --name "${local.runner_name}" \
        --labels nca,runner \
        --runnergroup default \
        --replace

      # Zonder --service: dit is een user-mode runner. Voor een service moet je
      # ./svc.sh install && ./svc.sh start gebruiken, wat extra root-vereisten
      # heeft die user-mode niet nodig heeft.
      nohup ./run.sh > /var/log/actions-runner.log 2>&1 &
      echo "Runner geregistreerd en gestart."
    else
      echo "Geen registration-token gevonden in SSM. De runner is geinstalleerd"
      echo "maar niet geregistreerd. Zie TESTPLAN.md test T7."
    fi
  EOF

  tags = {
    Name = "nca-github-runner"
    Role = "self-hosted-runner"
  }
}

# ------------------------------------------------------------
# Toegangsgegevens voor het inschakelen (na de eerste apply)
# ------------------------------------------------------------
resource "aws_ssm_parameter" "runner_registration_hint" {
  count = local.runner_enabled ? 1 : 0

  name        = "/github-actions/runner/setup-hint"
  type        = "String"
  value       = "Zet het registration-token hier: aws ssm put-parameter --name /github-actions/runner/registration-token --value <TOKEN> --type SecureString --overwrite"
  description = " instructie voor het registreren van de self-hosted runner"
}
