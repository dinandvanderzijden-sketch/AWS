# ============================================================
# GitHub Actions -> AWS via OpenID Connect
#
# Hier staat GEEN access key in en er is GEEN secret om in te vullen.
# GitHub stuurt bij het starten van een job een kort token mee (een JWT).
# De action aws-actions/configure-aws-credentials ruilt dat token in voor
# tijdelijke credentials via sts:AssumeRoleWithWebIdentity. Dat token leeft
# een paar minuten en is één keer bruikbaar.
#
# Wat je hiervoor in GitHub moet doen: niets. Geen secret aanmaken, geen
# sleutel plakken, niets roteren. De enige handmatige stap is één keer
# 'terraform apply' om de provider en rol hieronder aan te maken.
#
# Uitleg en de REQ-toewijzing staan in README.md.
# ============================================================

locals {
  owner = split("/", var.github_repo)[0]
  name  = split("/", var.github_repo)[1]

  # GitHub levert twee formaten van de 'sub'-claim:
  #   repo:owner/repo:ref:refs/heads/main
  #   repo:owner@<owner_id>/repo@<repo_id>:ref:refs/heads/main
  # De tweede, met numerieke IDs, is sinds 15 juli 2026 de standaard voor
  # bestaande repos; de eerste geldt voor oudere. We accepteren allebei, zodat
  # de trust policy blijft werken als je de repo ooit hernoemt of overzet.
  # De IDs staan in variables.tf, met uitleg hoe je ze opzoekt.
  subs_main = [
    "repo:${local.owner}/${local.name}:ref:refs/heads/main",
    "repo:${local.owner}@${var.github_owner_id}/${local.name}@${var.github_repo_id}:ref:refs/heads/main",
  ]

  # Rollen die deze stack zelf aanmaakt. Terraform heeft iam:PassRole nodig om
  # ze aan taken en instances door te geven, dus die permissie geven we per rol
  # apart. De verwijzingen zijn naar het Terraform-resource, dus de ARN klopt
  # automatisch. Let op de naam in AWS, die verschilt van het label hier links:
  #   aws_iam_role.ecs_execution_role -> production-ecs-execution-role
  #   aws_iam_role.ecs_task_role      -> production-ecs-task-role
  #   aws_iam_role.monitoring         -> monitoring-ec2-role
  #   aws_iam_role.codedeploy_role    -> ecs-codedeploy-role
  stack_role_arns = [
    aws_iam_role.ecs_execution_role.arn,
    aws_iam_role.ecs_task_role.arn,
    aws_iam_role.monitoring.arn,
    aws_iam_role.codedeploy_role.arn,
  ]
}

# ------------------------------------------------------------
# 1. De OIDC-provider: AWS' kant van de koppeling met GitHub
# ------------------------------------------------------------
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1b511abead59c6ce207077c0bf0e0043b1382592",
  ]

  tags = { Name = "github-actions-oidc" }
}

# ------------------------------------------------------------
# 2. De rol die de pipeline overneemt
#
# De trust policy is het beveiligingsonderdeel van deze hele aanpak. Er
# staat exact één ding in: de 'sub' van een push naar main in deze repo. Een
# pull request (ook uit deze repo zelf) krijgt sub "...:pull_request" en
# komt hier dus niet doorheen. Dat betekent dat alleen de main-branch iets
# kan uitrollen, en dat een fork of PR niets aan kan raken.
#
# Let op: als je ooit 'terraform plan' op een pull request wilt kunnen
# draaien, moet er 'pull_request' bij in subs_main en moet die rol
# read-only zijn. Bewust niet gedaan, zie README.md.
# ------------------------------------------------------------
resource "aws_iam_role" "github_actions" {
  name = "github-actions-deploy"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        # ForAnyValue accepteert de rol zodra de sub één van deze twee is.
        "ForAnyValue:StringEquals" = {
          "token.actions.githubusercontent.com:sub" = local.subs_main
        }
      }
    }]
  })

  tags = { Name = "github-actions-deploy" }
}

# PowerUserAccess dekt het aanmaken en wijzigen van de infrastructuur (VPC,
# ECS, RDS, ALB, ECR, CodeDeploy, autoscaling, ...). Het enige wat het níet
# doet is IAM, en deze stack maakt zelf rollen aan. Daarom de policy hier
# eronder.
resource "aws_iam_role_policy_attachment" "power_user" {
  role       = aws_iam_role.github_actions.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

data "aws_iam_policy_document" "iam_bootstrap" {
  # Rollen aanmaken kent geen resource-niveau, dus dat mag niet op een
  # specifieke rol staan. PassRole wél: dat geven we alleen voor de vier
  # rollen die deze stack zelf bezit.
  statement {
    sid    = "BeheerDeIamRollenEnPoliciesVanDezeStack"
    effect = "Allow"
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:ListRoles",
      "iam:UpdateRole", "iam:UpdateAssumeRolePolicy", "iam:TagRole",
      "iam:UntagRole", "iam:ListRoleTags", "iam:AttachRolePolicy",
      "iam:DetachRolePolicy", "iam:ListAttachedRolePolicies",
      "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetUserPolicy",
      "iam:ListRolePolicies", "iam:CreatePolicy", "iam:DeletePolicy",
      "iam:GetPolicy", "iam:GetPolicyVersion", "iam:ListPolicyVersions",
      "iam:ListEntitiesForPolicy", "iam:TagPolicy", "iam:UntagPolicy",
      "iam:CreateServiceLinkedRole",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "GeefAlleenDeVierStackrollenDoor"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = local.stack_role_arns
  }

  statement {
    sid    = "BeheerDeInstanceProfileVanDezeStack"
    effect = "Allow"
    actions = [
      "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile",
      "iam:GetInstanceProfile", "iam:ListInstanceProfiles",
      "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile", "iam:UntagInstanceProfile",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "GeefDeInstanceProfileDoor"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_instance_profile.monitoring.arn]
  }
}

resource "aws_iam_role_policy" "iam_bootstrap" {
  name   = "github-actions-deploy-iam-bootstrap"
  role   = aws_iam_role.github_actions.name
  policy = data.aws_iam_policy_document.iam_bootstrap.json
}

# Terraform haalt de state uit S3. Zonder dit kan 'terraform init' de backend
# niet eens openen. PowerUserAccess dekt S3 al volledig, dus dit is
# vooral een leesbaarheids- en documentatie-aanwinst: hier staat welke
# bucket het precies is.
data "aws_iam_policy_document" "state_bucket" {
  statement {
    sid       = "LeesDeStateBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = ["arn:aws:s3:::${var.tfstate_bucket}"]
  }

  statement {
    sid       = "LeesEnSchrijfStateObjects"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::${var.tfstate_bucket}/*"]
  }
}

resource "aws_iam_role_policy" "state_bucket" {
  name   = "github-actions-deploy-state-bucket"
  role   = aws_iam_role.github_actions.name
  policy = data.aws_iam_policy_document.state_bucket.json
}

# ------------------------------------------------------------
# Outputs - hiermee wordt de workflow handmatig een keer ingevuld
# ------------------------------------------------------------

output "github_actions_role_arn" {
  value       = aws_iam_role.github_actions.arn
  description = "Zet dit in .github/workflows/deploy.yml bij 'role-to-assume'."
}

output "github_oidc_provider_arn" {
  value       = aws_iam_openid_connect_provider.github.arn
  description = "De OIDC-provider. Verwijderen kan pas nadat 'allow_actions_to_access_oidc' op false staat."
}
