# ============================================================
# Tests voor REQ-NCA-P1-03 (containerized/configurable deployment),
# REQ-NCA-P1-04 (horizontal scaling + hoge beschikbaarheid) en
# REQ-NCA-P1-08 (git repo is de enige bron van waarheid).
# ============================================================

mock_provider "aws" {}
mock_provider "random" {}

# Waarden die in het echt pas na de apply bekend zijn (een RDS-endpoint, een
# ARN) zouden een 'command = plan'-test onbruikbaar maken: de conditie kan
# dan niet worden geëvalueerd. Met override_during = plan krijgen ze een
# vaste, realistische waarde tijdens het plannen. Zo blijft de test
# daadwerkelijk iets controleren in plaats van over te slaan.
# De IAM-policy's uit oidc.tf komen uit aws_iam_policy_document. Omdat de
# aws-provider hier gemockt is, levert die data source anders een mockwaarde
# in plaats van geldige JSON, en weigert de provider het 'policy'-argument.
# Hetzelfde JSON als in oidc.tf, zodat de tests de echte configuratie blijven
# controleren.
override_data {
  target          = data.aws_iam_policy_document.iam_bootstrap
  override_during = plan
  values = {
    json = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Sid      = "BeheerDeIamRollenEnPoliciesVanDezeStack"
          Effect   = "Allow"
          Action   = ["iam:CreateRole", "iam:DeleteRole", "iam:PutRolePolicy", "iam:AttachRolePolicy", "iam:CreatePolicy", "iam:DeletePolicy"]
          Resource = ["*"]
        },
        {
          Sid      = "GeefAlleenDeVierStackrollenDoor"
          Effect   = "Allow"
          Action   = ["iam:PassRole"]
          Resource = ["arn:aws:iam::491799435972:role/production-ecs-execution-role"]
        },
      ]
    })
  }
}

override_data {
  target          = data.aws_iam_policy_document.state_bucket
  override_during = plan
  values = {
    json = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Sid      = "LeesDeStateBucket"
          Effect   = "Allow"
          Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
          Resource = ["arn:aws:s3:::tfstate-eu-west-1-491799435972"]
        },
        {
          Sid      = "LeesEnSchrijfStateObjects"
          Effect   = "Allow"
          Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
          Resource = ["arn:aws:s3:::tfstate-eu-west-1-491799435972/*"]
        },
      ]
    })
  }
}

override_resource {
  target          = aws_db_instance.mariadb
  override_during = plan
  values = {
    address    = "appdb-mariadb.abc123.eu-west-1.rds.amazonaws.com"
    db_name    = "appdb"
    identifier = "appdb-mariadb"
  }
}

# De container_definitions is één JSON-string die deze ARNs bevat. Zonder
# overrides is die string 'unknown' tijdens de plan-fase en valt er niets te
# controleren.
override_resource {
  target          = aws_ecr_repository.app
  override_during = plan
  values = {
    repository_url = "491799435972.dkr.ecr.eu-west-1.amazonaws.com/nginx-app"
  }
}

override_resource {
  target          = aws_secretsmanager_secret.db_credentials
  override_during = plan
  values = {
    arn = "arn:aws:secretsmanager:eu-west-1:491799435972:secret:prod/mariadb/credentials-AbCdEf"
  }
}

override_resource {
  target          = aws_iam_role.ecs_execution_role
  override_during = plan
  values = {
    arn = "arn:aws:iam::491799435972:role/production-ecs-execution-role"
  }
}

override_resource {
  target          = aws_iam_role.ecs_task_role
  override_during = plan
  values = {
    arn = "arn:aws:iam::491799435972:role/production-ecs-task-role"
  }
}

override_resource {
  target          = aws_cloudwatch_log_group.nginx
  override_during = plan
  values = {
    name = "/ecs/nginx-task"
  }
}

# De ECS-service verwijst naar de subnetten via hun ID's. Zonder deze
# overrides is de subnetlijst 'unknown' tijdens de plan-fase en valt de
# HA-controle (2 AZ's) niet uit te voeren.
override_resource {
  target          = aws_subnet.web_private_a
  override_during = plan
  values = {
    id = "subnet-0aaaaaaaaaaaaaaaa"
  }
}

override_resource {
  target          = aws_subnet.web_private_b
  override_during = plan
  values = {
    id = "subnet-0bbbbbbbbbbbbbbbb"
  }
}

# ============================================================
# REQ-NCA-P1-03: applicatie is containerized en configuratie komt
# uit Secrets Manager, niet uit de code
# ============================================================

# De container_definitions zijn één JSON-blob. In een .tftest.hcl is er geen
# locals-blok beschikbaar, dus de decode staat in elke assertion. Dat is
# omslachtig maar wel controleerbaar.
run "wachtwoorden_staan_in_secrets_manager_en_niet_in_plaintext" {
  command = plan

  # DB_PASSWORD en DB_USERNAME horen via 'secrets' te lopen: dan staat er in
  # de taakdefinitie een verwijzing naar Secrets Manager in plaats van de
  # waarde zelf.
  assert {
    condition = length(try(
      [for c in jsondecode(aws_ecs_task_definition.nginx.container_definitions) : c.secrets
        if c.name == "nginx"
    ][0], [])) >= 2
    error_message = "De nginx-container gebruikt geen secrets. DB_PASSWORD hoort via Secrets Manager geïnjecteerd te worden."
  }

  assert {
    condition = alltrue([
      for s in try(
        [for c in jsondecode(aws_ecs_task_definition.nginx.container_definitions) : c.secrets
          if c.name == "nginx"
      ][0], []) : startswith(s.valueFrom, "arn:aws:secretsmanager:")
    ])
    error_message = "Een secret-verwijzing in de taakdefinitie verwijst niet naar Secrets Manager."
  }

  # En omgekeerd: geen environment-variabel waar 'wachtwoord' in de naam
  # staat. Daar zou de waarde als leesbare tekst in de taakdefinitie komen.
  assert {
    condition = alltrue([
      for e in try(
        [for c in jsondecode(aws_ecs_task_definition.nginx.container_definitions) : c.environment
          if c.name == "nginx"
      ][0], []) : !can(regex("(?i)password|secret", e.name))
    ])
    error_message = "Er staat een environment-variabel met 'password' of 'secret' in de naam. Dat hoort via 'secrets' te lopen."
  }

  # De environment bevat wél DB_HOST, met het adres uit de RDS-resource.
  assert {
    condition = contains(
      try([
        for c in jsondecode(aws_ecs_task_definition.nginx.container_definitions) : c.environment
        if c.name == "nginx"
      ][0], []).*.name,
      "DB_HOST"
    )
    error_message = "DB_HOST ontbreekt in de environment van de nginx-container."
  }
}

run "de_ecs_service_gebruikt_awsvpc_networking_en_codedeploy" {
  command = plan

  # 'awsvpc' is verplicht voor Fargate en voor het subnet-per-AZ-model.
  assert {
    condition     = aws_ecs_task_definition.nginx.network_mode == "awsvpc"
    error_message = "network_mode is niet 'awsvpc'; dan werken de subnetten per AZ en de security-groups-per-task niet."
  }

  # Zonder de CODE_DEPLOY-controller werkt de blue/green-deployment uit het
  # ontwerpdocument niet, en zou 'aws ecs update-service
  # --force-new-deployment' de verkeersshift overslaan.
  assert {
    condition     = aws_ecs_service.web.deployment_controller[0].type == "CODE_DEPLOY"
    error_message = "De service draait niet op de CODE_DEPLOY-controller. De blue/green-deployment werkt dan niet."
  }

  # Fargate-taken krijgen geen publiek IP: ze zitten achter de ALB.
  assert {
    condition     = aws_ecs_service.web.network_configuration[0].assign_public_ip == false
    error_message = "De taken krijgen een publiek IP-adres. Ze horen alleen via de ALB bereikbaar te zijn (REQ-NCA-P1-02)."
  }
}

run "container_insights_staat_aan" {
  command = plan

  # Zonder dit werkt de memory_utilization-metric - en dus het memory-alarm
  # in alarms.tf en het geheugenpaneel in het dashboard - niet.
  assert {
    condition     = length([for s in aws_ecs_cluster.main.setting : s if s.name == "containerInsights" && s.value == "enabled"]) == 1
    error_message = "Container Insights staat niet aan op het ECS-cluster; de geheugenmetriek en het bijbehorende alarm werken dan niet."
  }
}

# ============================================================
# REQ-NCA-P1-04: minimaal 2 taken, autoscaling, blue/green
# ============================================================

run "er_draaien_minimaal_twee_taken_spread_over_twee_azs" {
  command = plan

  # REQ-NCA-P1-04: "Minimaal 2 NGINX-taken verspreid over 2 Availability Zones."
  assert {
    condition     = aws_ecs_service.web.desired_count >= 2
    error_message = "desired_count is ${aws_ecs_service.web.desired_count}; onder de HA-eis van 2 taken."
  }

  assert {
    condition     = length(aws_ecs_service.web.network_configuration[0].subnets) >= 2
    error_message = "De service draait op ${length(aws_ecs_service.web.network_configuration[0].subnets)} subnet(en). Voor HA over 2 AZ's zijn er 2 nodig."
  }

  # Twee verschillende subnetten, dus echt twee AZ's.
  assert {
    condition     = length(distinct(aws_ecs_service.web.network_configuration[0].subnets)) == 2
    error_message = "De twee subnetten van de service zijn identiek; dan draait alles in één AZ."
  }
}

run "autoscaling_schaalt_omhoog_en_terug" {
  command = plan

  assert {
    condition     = aws_appautoscaling_target.ecs_target.min_capacity == 2
    error_message = "min_capacity is niet 2; dat is de minimale HA-configuratie."
  }

  assert {
    condition     = aws_appautoscaling_target.ecs_target.max_capacity >= aws_appautoscaling_target.ecs_target.min_capacity
    error_message = "max_capacity (${aws_appautoscaling_target.ecs_target.max_capacity}) ligt onder min_capacity (${aws_appautoscaling_target.ecs_target.min_capacity})."
  }

  # Het maximum is een variabele geworden, zodat de piekbelasting uit de
  # TCO-analyse ingesteld kan worden zonder dat de code aangepast hoeft te
  # worden (REQ-NCA-P1-08).
  assert {
    condition     = aws_appautoscaling_target.ecs_target.max_capacity == var.max_task_count
    error_message = "max_capacity volgt var.max_task_count niet meer."
  }

  # De stapgewijze drempels uit het ontwerpdocument: +2 boven 70%, -2 onder 20%.
  # 'step_adjustment' is een set, dus niet te indexeren - vandaar de for-loop.
  assert {
    condition     = contains([for sa in aws_appautoscaling_policy.scale_out.step_scaling_policy_configuration[0].step_adjustment : sa.scaling_adjustment], 2)
    error_message = "scale-out telt niet 2 taken op; het ontwerpdocument schrijft +2 voor."
  }

  assert {
    condition     = contains([for sa in aws_appautoscaling_policy.scale_in.step_scaling_policy_configuration[0].step_adjustment : sa.scaling_adjustment], -2)
    error_message = "scale-in haalt niet 2 taken eraf; het ontwerpdocument schrijft -2 voor."
  }
}

run "de_listener_en_service_geven_hun_eigenaar_vrij_aan_codedeploy" {
  command = plan

  # CodeDeploy is eigenaar van de default_action zodra blue/green draait.
  # Zonder ignore_changes zou elke `terraform apply` de listener terug op
  # blue zetten en de deployment ongedaan maken.
  #
  # 'ignore_changes' is een meta-argument en geen attribuut, dus het is niet
  # via de resource-graph te bevragen. Daarom wordt hier de broncode gelezen:
  # dat is de enige plek waar deze instelling staat, en als iemand hem
  # weghaalt faalt deze test.
  assert {
    condition     = strcontains(file("${path.module}/compute.tf"), "ignore_changes = [default_action]")
    error_message = "De ALB-listener heeft geen 'ignore_changes = [default_action]'. Elke terraform apply zou het verkeer terugzetten op de blue target group."
  }

  # Idem voor de ECS-service: CodeDeploy beheert de taakdefinitie en de
  # target group na de eerste deployment.
  assert {
    condition     = strcontains(file("${path.module}/compute.tf"), "ignore_changes = [task_definition, load_balancer]")
    error_message = "De ECS-service geeft task_definition of load_balancer niet vrij aan CodeDeploy; elke infra-apply zou de uitgerolde image terugzetten."
  }
}

run "er_is_een_blauw_en_een_groen_target_group" {
  command = plan

  assert {
    condition     = aws_lb_target_group.blue.name != aws_lb_target_group.green.name
    error_message = "Blue en green hebben dezelfde naam; dat kan niet, en zou de deployment laten struikelen."
  }

  assert {
    condition     = aws_lb_target_group.blue.health_check[0].path == "/healthz" && aws_lb_target_group.green.health_check[0].path == "/healthz"
    error_message = "Blue en green checken niet op /healthz; dan zou een taak die nog niet klaar is toch verkeer krijgen."
  }

  # De listener doet een 'forward' naar de blue target group; na de eerste
  # CodeDeploy-deployment wijst hij naar green (en Terraform velt dat niet
  # meer aan dankzij ignore_changes).
  assert {
    condition     = aws_lb_listener.http.default_action[0].type == "forward"
    error_message = "De listener doet geen 'forward'; dan kan de blue/green-deployment het verkeer niet verschuiven."
  }
}

# ============================================================
# REQ-NCA-P1-08: geen tweede bron van waarheid
# ============================================================

run "de_resource_namen_staan_niet_hardcoded_in_task_definition_json" {
  command = plan

  # task-definition.json is de basis die de pipeline rendert. Stond daar een
  # echt RDS-endpoint in, dan wijst de uitgerolde taak naar een adres dat
  # Terraform inmiddens heeft vervangen. De pipeline overschrijft DB_HOST nu
  # vanuit de Terraform-output (deploy.yml, stap 'Render new task definition').
  assert {
    condition     = strcontains(file("${path.module}/task-definition.json"), "SET_BY_PIPELINE_FROM_TERRAFORM_OUTPUT")
    error_message = "task-definition.json bevat een hardcoded DB_HOST. De pipeline moet die uit de Terraform-output halen, anders wijst de taak naar een oud database-adres."
  }

  # En het endpoint uit Terraform komt er ook echt in: de environment in
  # compute.tf verwijst naar het adres van de RDS-resource, niet naar een
  # handgeschreven string.
  assert {
    condition     = strcontains(aws_ecs_task_definition.nginx.container_definitions, aws_db_instance.mariadb.address)
    error_message = "De taakdefinitie bevat het DB-adres niet uit de RDS-resource; dan is er wél een tweede bron van waarheid."
  }
}
