# ============================================================
# GitHub Actions <-> AWS via OpenID Connect (GEEN access keys meer)
#
# PROBLEEM DAT DIT OPLOST
# De workflow gebruikte statische keys uit GitHub Secrets:
#   AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN
# Die zijn (a) lang geldig, dus lekken blijft toegang geven, (b) handmatig
# gerouleerd moeten worden, en (c) staan in een repo die je naar AWS toe pusht.
#
# HOE HET WERKT
# 1. GitHub Actions krijgt bij het starten van een job een kortlopend OIDC-token
#    (een JWT met o.a. een 'sub'-claim als "repo:OWNER/REPO:ref:refs/heads/main").
# 2. De aws-actions/configure-aws-credentials-action ruilt dat token in voor
#    tijdelijke credentials via sts:AssumeRoleWithWebIdentity.
# 3. Er is dus GEEN access key meer die je hoeft in te vullen of op te slaan.
#    Elk token is ~5 minuten geldig en 1x bruikbaar.
#
# BOOTSTRAP: de OIDC-provider en de rollen hieronder moeten bestaan VOORDAT de
# workflow ze kan gebruiken. De eerste apply doe je dus nog lokaal (of met je
# oude keys). Daarna kun je AWS_ACCESS_KEY_ID et al uit GitHub Secrets verwijderen.
# Zie README-OIDC.md voor de volgorde.
# ============================================================

locals {
  # De exacte 'sub'-claims die GitHub meestuurt in het OIDC-token. LET OP:
  # sinds kort bevat sub de numerieke IDs, dus het is NIET meer
  # "repo:owner/repo:ref:..." maar:
  #   repo:<owner>@<owner_id>/<repo>@<repo_id>:ref:refs/heads/<branch>
  # Beide staan hieronder gecontroleerd getest tegen een echt token.
  # Met de ID-vorm vergelijk je op IDs in plaats van namen: een repo kan
  # hernoemd worden, een ID niet. Dat is veiliger tegen een repo die een
  # gelijkende naam krijgt aangemaakt.
  github_sub_branch = "repo:${var.github_owner}@${var.github_owner_id}/${var.github_repo_name}@${var.github_repo_id}:ref:refs/heads/${var.github_branch}"
  github_sub_pr     = "repo:${var.github_owner}@${var.github_owner_id}/${var.github_repo_name}@${var.github_repo_id}:pull_request"

  # De rollen die deze stack zelf aanmaakt. Terraform heeft iam:PassRole nodig
  # voor deze resources, en we scopen die permissie bewust per rol.
  managed_role_arns = [
    aws_iam_role.ecs_execution_role.arn,
    aws_iam_role.ecs_task_role.arn,
    aws_iam_role.monitoring.arn,
    aws_iam_role.codedeploy_role.arn,
  ]

  managed_instance_profile_arns = [
    aws_iam_instance_profile.monitoring.arn,
  ]
}

# ------------------------------------------------------------
# 1. De OIDC-provider: dit is AWS' kant van de koppeling met GitHub
# ------------------------------------------------------------
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # AWS haalt de thumbprints inmiddels zelf op; deze zijn nog verplicht in de
  # Terraform AWS-provider en komen uit de AWS-documentatie voor GitHub Actions.
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1b511abead59c6ce207077c0bf0e0043b1382592",
  ]

  tags = { Name = "github-actions-oidc" }
}

# ------------------------------------------------------------
# 2. Deploy-role: alleen een push naar de main-branch mag deze overnemen
#
# De trust-policy is het belangrijkste beveiligingsonderdeel van deze hele
# aanpak. De 'sub'-claim die GitHub meestuurt is exact
#   "repo:<owner>@<owner_id>/<repo>@<repo_id>:ref:refs/heads/main"
# en STS accepteert de rol alleen als die string klopt. Iemand met alleen
# pull-rechten op de repo kan 'main' dus niet misbruiken om te deployen.
#
# Let op de @<id>-delen: GitHub gebruikt tegenwoordig die numerieke vorm, niet
# de oudere "repo:<owner>/<repo>:...". Zie locals.github_sub_branch hieronder;
# de strings zijn daar gecontroleerd getest tegen een echt token.
# ------------------------------------------------------------
resource "aws_iam_role" "github_actions_deploy" {
  name = "github-actions-deploy"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "sts:AssumeRoleWithWebIdentity"
      Principal = {
        Federated = aws_iam_openid_connect_provider.github.arn
      }
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = local.github_sub_branch
        }
      }
    }]
  })

  tags = { Name = "github-actions-deploy" }
}

# PowerUserAccess dekt het aanmaken/wijzigen/verwijderen van al je infra
# (VPC, ECS, RDS, ECR, ALB, TGW, KMS, Secrets, CodeDeploy, autoscaling...).
# Het enige wat PowerUserAccess níet doet is IAM, en deze stack maakt zelf
# IAM-rollen aan - daarom de aanvullende policy hieronder.
resource "aws_iam_role_policy_attachment" "deploy_power_user" {
  role       = aws_iam_role.github_actions_deploy.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

data "aws_iam_policy_document" "deploy_iam_bootstrap" {
  # Rollen/policies aanmaken kan niet aan een resource worden gescoord
  # (CreateRole kent nog geen resource-niveau), dus dat staat op "*".
  # PassRole - het daadwerkelijk "dragen" van een rol aan een service -
  # is wél te beperken tot de rollen in deze stack.
  statement {
    sid    = "ManageIAMResourcesCreatedByThisStack"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:ListRoles",
      "iam:UpdateRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:DeleteRolePermissionsBoundary",
      "iam:PutRolePermissionsBoundary",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:ListRoleTags",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:ListPolicyVersions",
      "iam:ListEntitiesForPolicy",
      "iam:TagPolicy",
      "iam:UntagPolicy",
      "iam:CreateServiceLinkedRole",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "PassOnlyTheRolesThisStackOwns"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = local.managed_role_arns
  }

  statement {
    sid    = "ManageTheInstanceProfileThisStackOwns"
    effect = "Allow"
    actions = [
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:GetInstanceProfile",
      "iam:ListInstanceProfiles",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:UntagInstanceProfile",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "AttachTheInstanceProfileThisStackOwns"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = local.managed_instance_profile_arns
  }
}

resource "aws_iam_role_policy" "deploy_iam_bootstrap" {
  name   = "github-actions-deploy-iam-bootstrap"
  role   = aws_iam_role.github_actions_deploy.name
  policy = data.aws_iam_policy_document.deploy_iam_bootstrap.json
}

# Lezen en schrijven van de Terraform state gaat via S3; zonder dit kan
# 'terraform init' de backend niet eens openen.
data "aws_iam_policy_document" "deploy_state_bucket" {
  statement {
    sid       = "ListStateBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketVersions", "s3:ListBucketMultipartUploads"]
    resources = ["arn:aws:s3:::${var.tfstate_bucket}"]
  }

  statement {
    sid       = "ReadWriteStateObjects"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:GetObjectVersion", "s3:DeleteObjectVersion"]
    resources = ["arn:aws:s3:::${var.tfstate_bucket}/*"]
  }
}

resource "aws_iam_role_policy" "deploy_state_bucket" {
  name   = "github-actions-deploy-state-bucket"
  role   = aws_iam_role.github_actions_deploy.name
  policy = data.aws_iam_policy_document.deploy_state_bucket.json
}

# ------------------------------------------------------------
# 3. Plan-role: read-only, voor pull requests en 'terraform plan'
#
# Splitsen van plan en deploy is de belangrijkste beveiligingscontrole in
# deze setup: een pull request uit een fork levert een OIDC-token met sub
# "repo:dinandvanderzijden-sketch/AWS:pull_request", dus die kan ALLEEN
# deze read-only rol overnemen. Er is geen enkele schrijfactie toegestaan.
# ------------------------------------------------------------
resource "aws_iam_role" "github_actions_plan" {
  name = "github-actions-plan"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      # Push naar main: dezelfde subject als de deploy-role, maar hier read-only.
      [{
        Effect    = "Allow"
        Action    = "sts:AssumeRoleWithWebIdentity"
        Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
            "token.actions.githubusercontent.com:sub" = local.github_sub_branch
          }
        }
      }],
      var.enable_pr_plan_role ? [{
        Effect    = "Allow"
        Action    = "sts:AssumeRoleWithWebIdentity"
        Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
            "token.actions.githubusercontent.com:sub" = local.github_sub_pr
          }
        }
      }] : []
    )
  })

  tags = { Name = "github-actions-plan" }
}

resource "aws_iam_role_policy_attachment" "plan_read_only" {
  role       = aws_iam_role.github_actions_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# Let op: ReadOnlyAccess geeft ook leesrechten op IAM (iam:Get*/List*). Dat is
# acceptabel voor een plan - er kan niets worden aangemaakt, gewijzigd of
# verwijderd, dus er valt niets te exfiltreren behalve metadata. Wil je dat
# liever dicht, dan moet er een expliciete Deny bij, maar dan moet je
# opletten dat 'terraform plan' niet stukloopt zodra er iets nieuws is.

# ============================================================
# Outputs - dit vul je in bij 'role-to-assume' in de workflow
# ============================================================

output "github_actions_deploy_role_arn" {
  value       = aws_iam_role.github_actions_deploy.arn
  description = "Zet dit in .github/workflows/deploy.yml bij 'role-to-assume' voor de deploy-job."
}

output "github_actions_plan_role_arn" {
  value       = aws_iam_role.github_actions_plan.arn
  description = "Zet dit in .github/workflows/deploy.yml bij 'role-to-assume' voor de plan-job."
}

output "github_oidc_provider_arn" {
  value       = aws_iam_openid_connect_provider.github.arn
  description = "De OIDC-provider. Verwijderen kan pas nadat je 'allow_actions_to_access_oidc' op false hebt gezet."
}
