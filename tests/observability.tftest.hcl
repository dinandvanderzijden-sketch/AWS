# ============================================================
# Tests voor REQ-NCA-P1-05 (observability: dashboard + notificatie),
# REQ-NCA-P1-06 (vergrendelde remote state) en REQ-NCA-P1-07
# (pipeline met preview en tests).
# ============================================================

mock_provider "aws" {}
mock_provider "random" {}

# LET OP: een .tftest.hcl-bestand kent geen locals-blok. De state-bucket
# staat daarom als letterlijke string in de assert hieronder; hij moet
# overeenkomen met het backend-blok in main.tf.

# Zie de toelichting in application.tftest.hcl: waarden die pas na de apply
# bekend zijn, worden hier met override_during = plan vastgezet zodat de
# condities tijdens het plannen te evalueren zijn.
override_resource {
  target          = aws_db_instance.mariadb
  override_during = plan
  values = {
    address    = "appdb-mariadb.abc123.eu-west-1.rds.amazonaws.com"
    db_name    = "appdb"
    identifier = "appdb-mariadb"
  }
}

override_resource {
  target          = aws_lb.external_alb
  override_during = plan
  values = {
    arn        = "arn:aws:elasticloadbalancing:eu-west-1:491799435972:loadbalancer/app/hub-alb/0123456789abcdef"
    arn_suffix = "app/hub-alb/0123456789abcdef"
    dns_name   = "hub-alb-1234567890.eu-west-1.elb.amazonaws.com"
  }
}

override_resource {
  target          = random_password.grafana_admin
  override_during = plan
  values = {
    result = "testgrafana0wachtwoord"
  }
}

override_data {
  target          = data.aws_caller_identity.current
  override_during = plan
  values = {
    account_id = "491799435972"
  }
}

override_data {
  target          = data.aws_ami.al2023
  override_during = plan
  values = {
    id = "ami-0123456789abcdef0"
  }
}

# De SNS-topic-ARN is de koppeling tussen elk alarm en het notificatiekanaal.
# Zonder override is die waarde onbekend en kan de belangrijkste test van
# REQ-NCA-P1-05 (hangt elk alarm aan de topic?) niet lopen.
override_resource {
  target          = aws_sns_topic.alerts
  override_during = plan
  values = {
    arn = "arn:aws:sns:eu-west-1:491799435972:nca-infra-alerts"
  }
}

# De runner-tests controleren in welk subnet de instantie staat; dat vergelijkt
# twee subnet-ID's die pas na de apply bestaan.
override_resource {
  target          = aws_subnet.hub_mgmt
  override_during = plan
  values = {
    id = "subnet-0cccccccccccccccc"
  }
}

# ============================================================
# REQ-NCA-P1-05: dashboard
# ============================================================

run "het_grafana_dashboard_bevat_de_metrieken_en_drempels_uit_het_ontwerpdocument" {
  command = plan

  # Zeven panelen: zes uit de tabel "Onderbouwing Monitorde Metrieken &
  # Drempeloverschrijdingen" plus één nginx-paneel op Prometheus.
  assert {
    condition     = length(local.dashboard.panels) == 7
    error_message = "Het dashboard heeft ${length(local.dashboard.panels)} panelen; het zou er 7 moeten zijn."
  }

  # De vier drempelgebaseerde metrieken moeten met de juiste drempel in het
  # dashboard staan. Dit is de koppeling tussen het ontwerpdocument en de code.
  assert {
    condition = alltrue([
      for want in [
        { namespace = "AWS/ECS", metric = "CPUUtilization", threshold = 70 },
        { namespace = "ECS/ContainerInsights", metric = "memory_utilization", threshold = 80 },
        { namespace = "AWS/ApplicationELB", metric = "TargetResponseTime", threshold = 0.5 },
        { namespace = "AWS/RDS", metric = "CPUUtilization", threshold = 85 },
      ] :
      anytrue([
        for p in local.dashboard.panels :
        p.datasource.type == "cloudwatch" &&
        p.targets[0].namespace == want.namespace &&
        p.targets[0].metricName == want.metric &&
        p.fieldConfig.defaults.thresholds.steps[1].value == want.threshold
      ])
    ])
    error_message = "Niet alle vier de drempelwaarden (70% CPU, 80% geheugen, 500ms, 85% DB-CPU) staan met de juiste drempel in het dashboard. Zie de tabel in het ontwerpdocument."
  }

  # De verplichte panelen moeten op CloudWatch draaien. Prometheus kan de
  # ECS-taken zonder cross-VPC DNS niet oplossen (zie TESTPLAN.md T4); als de
  # panelen uit de tabel daarvan afhingen, zou het dashboard leeg zijn.
  assert {
    condition     = length([for p in local.dashboard.panels : p if p.datasource.type == "cloudwatch"]) == 6
    error_message = "Er moeten 6 CloudWatch-panelen zijn; Prometheus levert alleen de optionele nginx-metrieken."
  }

  # De cloudwatch-datasource moet in de provisioning ook echt bestaan, anders
  # blijven alle panelen leeg. De uid moet overeenkomen met die in het
  # dashboard.
  assert {
    condition     = strcontains(local.monitoring_user_data, "uid: cloudwatch")
    error_message = "De datasource-provisioning op de instance mist de uid 'cloudwatch' die het dashboard gebruikt."
  }

  assert {
    condition     = strcontains(local.monitoring_user_data, "/opt/monitoring/grafana/dashboards")
    error_message = "De user_data zet de grafana-dashboardmap niet klaar; dan wordt er geen dashboard geladen."
  }

  # Het dashboard wordt als JSON-bestand op de instance geschreven. Zonder die
  # schrijfstap blijft de map leeg en toont Grafana een leeg scherm.
  assert {
    condition     = strcontains(local.monitoring_user_data, "nca-overview.json")
    error_message = "De user_data schrijft het dashboardbestand niet weg."
  }
}

run "elk_alarm_meldt_zich_via_sns" {
  command = plan

  # REQ-NCA-P1-05: "een overschrijding van kritieke drempelwaarden triggert
  # binnen 1 minuut een notificatie." Een alarm zonder alarm_actions geeft
  # niemand een seintje.
  assert {
    condition = alltrue([
      for a in [
        aws_cloudwatch_metric_alarm.alb_5xx_rate,
        aws_cloudwatch_metric_alarm.alb_latency,
        aws_cloudwatch_metric_alarm.ecs_memory,
        aws_cloudwatch_metric_alarm.rds_cpu,
        aws_cloudwatch_metric_alarm.alb_unhealthy,
        aws_cloudwatch_metric_alarm.cpu_high,
        aws_cloudwatch_metric_alarm.cpu_low,
      ] : contains(a.alarm_actions, aws_sns_topic.alerts.arn)
    ])
    error_message = "Niet elk alarm is gekoppeld aan de SNS-topic; zonder alarm_actions gaat er geen notificatie uit."
  }

  # Binnen 1 minuut detecteren: 1 tot 5 evaluatieperiodes van 60 seconden.
  # De CPU-alarms voor autoscaling mogen wél meerdere periodes hebben (5x en
  # 10x), anders schaalt het systeem op één CPU-piek.
  assert {
    condition = alltrue([
      for a in [
        aws_cloudwatch_metric_alarm.alb_5xx_rate,
        aws_cloudwatch_metric_alarm.alb_latency,
        aws_cloudwatch_metric_alarm.ecs_memory,
        aws_cloudwatch_metric_alarm.rds_cpu,
      ] : a.evaluation_periods == 1
    ])
    error_message = "Een van de vier kritieke alarms heeft meer dan 1 evaluatieperiode; dan duurt de notificatie langer dan de vereiste minuut."
  }

  # De 5xx-alarm moet een percentage rekenen, niet een absoluut aantal: het
  # ontwerpdocument noemt 1% van het totale verkeer.
  assert {
    condition     = aws_cloudwatch_metric_alarm.alb_5xx_rate.threshold == 1
    error_message = "De 5xx-drempel is geen 1%. Zonder percentage zou 1 verzoeg per minuut al een alarm geven."
  }

  assert {
    condition     = strcontains(jsonencode(aws_cloudwatch_metric_alarm.alb_5xx_rate.metric_query), "err5xx / requests")
    error_message = "De 5xx-alarm rekent geen percentage uit; hij telt alleen absolute aantallen."
  }
}

run "het_ha_alarm_overleeft_een_blue_green_switch" {
  command = plan

  # De HealthyHostCount-metric bestaat per target group. Als dit alarm een
  # TargetGroup-dimension zou hebben, meet het na een blue/green-switch een
  # group die geen verkeer meer krijgt, en slaat het onterecht aan. Met alleen
  # de LoadBalancer-dimension telt CloudWatch over alle groups en pakt
  # stat = "Minimum" het zwakste - precies wat de HA-eis vraagt.
  # NB: alleen 'metric_query' wordt gecodeerd. Het hele resource-object bevat
  # ook attributen als 'id' en 'alarm_arn' die pas na de apply bestaan, en
  # die zouden de conditie 'unknown' maken.
  assert {
    condition     = !strcontains(jsonencode(aws_cloudwatch_metric_alarm.alb_unhealthy.metric_query), "TargetGroup")
    error_message = "Het HA-alarm heeft een TargetGroup-dimension. Na een blue/green-switch meet het dan een group die niet meer actueel is en gaat het vals af. Laat de dimension weg en gebruik stat = \"Minimum\"."
  }

  assert {
    condition     = jsondecode(jsonencode(aws_cloudwatch_metric_alarm.alb_unhealthy.metric_query))[0].metric[0].stat == "Minimum"
    error_message = "Het HA-alarm gebruikt niet stat = \"Minimum\". Zonder Minimum zou het aantal gezonde taken over álle target groups heen worden opgeteld in plaats van dat het zwakste wordt beoordeeld."
  }

  # De drempel is de HA-eis zelf: minimaal 2 taken.
  assert {
    condition     = aws_cloudwatch_metric_alarm.alb_unhealthy.threshold == 2 && aws_cloudwatch_metric_alarm.alb_unhealthy.comparison_operator == "LessThanThreshold"
    error_message = "Het HA-alarm hoort bij minder dan 2 gezonde taken te slaan; dat is de eis uit REQ-NCA-P1-04."
  }
}

run "de_drempels_van_het_dashboard_en_die_van_de_alarms_zijn_gelijk" {
  command = plan

  # Als het dashboard 70% toont en het alarm bij 60% afgaat, is een van de twee
  # fout. Deze test dwingt één getal.
  assert {
    condition = alltrue([
      for pair in [
        { dashboard_threshold = 70, alarm = aws_cloudwatch_metric_alarm.cpu_high.threshold },
        { dashboard_threshold = 20, alarm = aws_cloudwatch_metric_alarm.cpu_low.threshold },
        { dashboard_threshold = 80, alarm = aws_cloudwatch_metric_alarm.ecs_memory.threshold },
        { dashboard_threshold = 85, alarm = aws_cloudwatch_metric_alarm.rds_cpu.threshold },
        { dashboard_threshold = 0.5, alarm = aws_cloudwatch_metric_alarm.alb_latency.threshold },
      ] : pair.dashboard_threshold == pair.alarm
    ])
    error_message = "Een drempel in een alarm wijkt af van de drempel die het dashboard toont. Ze horen dezelfde bron te hebben."
  }
}

# ============================================================
# REQ-NCA-P1-06: vergrendelde remote state
# ============================================================

run "de_remote_state_ligt_in_een_bucket_met_locking" {
  command = plan

  # use_lockfile = true zet het native S3-lockfile-mechanisme aan: een
  # tweede gelijktijdige plan/apply wacht tot de eerste klaar is. Zonder dit
  # kunnen twee pipelines dezelfde state tegelijk overschrijven.
  #
  # De backend-configuratie zelf leeft buiten de resource-graph, dus die is
  # hier alleen als broncode te controleren. Of hij echt werkt, bewijst de
  # stap `terraform init` in de pipeline.
  assert {
    condition     = strcontains(file("${path.module}/main.tf"), "use_lockfile = true")
    error_message = "Locking staat niet aan in de backend-configuratie van main.tf. Zonder vergrendeling overschrijven twee gelijktijdige runs elkaars state."
  }

  assert {
    condition     = strcontains(file("${path.module}/main.tf"), "key          = \"terraform/state.tfstate\"") || strcontains(file("${path.module}/main.tf"), "key = \"terraform/state.tfstate\"")
    error_message = "De state staat niet op de verwachte sleutel; de IAM-permissies hieronder kloppen dan niet."
  }

  # De credentials waarmee de pipeline draait, moeten de state-bucket kunnen
  # lezen en schrijven. Die rechten zitten niet meer in deze stack maar in de
  # IAM-user 'github-actions-deploy' (zie README.md), dus controleer hier alleen
  # dat de backend-configuratie en de regels in README/TESTPLAN niet uit elkaar
  # zijn gelopen: de bucketnaam moet in de documentatie overeenkomen met die in
  # het backend-blok.
  assert {
    condition     = strcontains(file("${path.module}/main.tf"), "bucket       = \"tfstate-eu-west-1-491799435972\"") || strcontains(file("${path.module}/main.tf"), "bucket = \"tfstate-eu-west-1-491799435972\"")
    error_message = "De state-bucket in het backend-blok van main.tf wijkt af van die in de documentatie (README.md, TESTPLAN.md T10)."
  }
}

# ============================================================
# REQ-NCA-P1-07: pipeline - authenticatie, preview, tests
# ============================================================

run "de_pipeline_logt_in_met_aws_sleutels_uit_github_secrets" {
  command = plan

  # Authenticatie loopt via een IAM-user in GitHub Secrets. De OIDC-provider en
  # de bijbehorende rollen zijn uit de stack verwijderd, dus de workflow mag
  # nergens meer naar een OIDC-rol verwijzen.
  assert {
    condition     = strcontains(file("${path.module}/.github/workflows/deploy.yml"), "aws-access-key-id: $${{ secrets.AWS_ACCESS_KEY_ID }}")
    error_message = "De workflow leest AWS_ACCESS_KEY_ID niet uit de GitHub-secrets; zonder die configuratie kan hij niet inloggen."
  }

  assert {
    condition     = strcontains(file("${path.module}/.github/workflows/deploy.yml"), "aws-secret-access-key: $${{ secrets.AWS_SECRET_ACCESS_KEY }}")
    error_message = "De workflow leest AWS_SECRET_ACCESS_KEY niet uit de GitHub-secrets."
  }

  assert {
    condition     = !strcontains(file("${path.module}/.github/workflows/deploy.yml"), "role-to-assume")
    error_message = "De workflow gebruikt nog 'role-to-assume'; die OIDC-rol bestaat niet meer, dus de job faalt met AccessDenied."
  }

  assert {
    condition     = !strcontains(file("${path.module}/.github/workflows/deploy.yml"), "id-token")
    error_message = "De workflow vraagt nog een id-token aan; dat is alleen nodig voor OIDC en is inmiddels een overbodige permissie."
  }

  # Least privilege: statische keys blijven geldig na het verwijderen van de
  # repo, dus ze horen bij een eigen IAM-user - niet bij een persoonlijke
  # sleutel of het root-account. De guard faalt hard in plaats van stilzwijgend
  # met de verkeerde sleutel te draaien.
  assert {
    condition     = strcontains(file("${path.module}/.github/workflows/deploy.yml"), "arn:aws:iam::*:user/github-actions-deploy")
    error_message = "De workflow controleert niet of hij met de IAM-user github-actions-deploy inlogt; zonder die guard zou een per ongeluk ingevulde persoonlijke sleutel stilletjes doorwerken."
  }

  # Fork-PR's krijgen geen secrets van GitHub. Zonder deze guard zou de
  # plan-job daar elke keer op een authenticatiefout struikelen in plaats van
  # netjes te worden overgeslagen.
  assert {
    condition     = strcontains(file("${path.module}/.github/workflows/deploy.yml"), "github.event.pull_request.head.repo.full_name == github.repository")
    error_message = "De plan-job slaat PR's uit een fork niet over; die krijgen geen secrets en zouden de job laten falen."
  }
}

run "de_self_hosted_runner_staat_in_het_management_subnet_zonder_publiek_ip" {
  command = plan

  variables {
    enable_self_hosted_runner = true
    admin_cidr                = "203.0.113.10/32"
  }

  # REQ-NCA-P1-07: "binnen de eigen netwerkgrenzen".
  assert {
    condition     = aws_instance.runner[0].associate_public_ip_address == false
    error_message = "De runner heeft een publiek IP-adres; dat is in strijd met de eis dat hij binnen de eigen netwerkgrenzen draait."
  }

  assert {
    condition     = aws_instance.runner[0].subnet_id == aws_subnet.hub_mgmt.id
    error_message = "De runner draait niet in het afgeschermde management-subnet."
  }

  # Twee tags die aantonen dat hier een runner hoort: zonder deze labels
  # is de machine in de console niet van een gewone EC2 te onderscheiden.
  assert {
    condition     = aws_instance.runner[0].tags["Role"] == "self-hosted-runner"
    error_message = "De runner mist de tag Role = self-hosted-runner."
  }
}

run "de_runner_staat_standaard_uit_zodat_de_pipeline_niet_hangt" {
  command = plan

  # Een workflow die naar een self-hosted runner wijst terwijl die niet
  # geregistreerd is, blijft hangen op 'Waiting for a runner'. Dan valt de
  # hele uitrol stil, inclusief de apply die de runner zelf zou aanmaken.
  # De inschakelstappen staan in TESTPLAN.md (T7).
  assert {
    condition     = var.enable_self_hosted_runner == false
    error_message = "Deze test draait op de default; enable_self_hosted_runner hoort standaard false te zijn."
  }

  assert {
    condition     = length(aws_instance.runner) == 0
    error_message = "Er draaien runners terwijl de variabelie uit staat."
  }
}

# ============================================================
# REQ-NCA-P1-08: de pipeline haalt zijn namen uit Terraform
# ============================================================

run "de_pipeline_haalt_zijn_namen_uit_terraform_in_plaats_van_hardcoded_strings" {
  command = plan

  # Dit is de kern van REQ-NCA-P1-08: de git-repo mag de enige bron van
  # waarheid zijn. Zolang de pipeline cluster-, service- en CodeDeploy-namen
  # uit `terraform output` haalt, kan er geen tweede bron ontstaan.
  #
  # Vroeger stonden deze namen letterlijk in deploy.yml én in
  # task-definition.json. Wie toen een service hernoemde, kreeg een pipeline
  # die naar een naam uit het verleden deployde - zonder foutmelding.
  assert {
    condition = alltrue([
      for output_name in [
        "ecs_cluster_name",
        "ecs_service_name",
        "codedeploy_app_name",
        "codedeploy_deployment_group_name",
        "ecr_repository_url",
        "database_endpoint",
      ] :
      strcontains(file("${path.module}/.github/workflows/deploy.yml"), "terraform output -raw ${output_name}")
    ])
    error_message = "De workflow haalt minstens één van deze namen niet uit de Terraform-output. Dan is de pipeline een tweede bron van waarheid (REQ-NCA-P1-08)."
  }

  assert {
    condition     = !strcontains(file("${path.module}/.github/workflows/deploy.yml"), "production-ecs-cluster")
    error_message = "De workflow bevat de clusternaam als hardcoded string. Haal hem op via `terraform output -raw ecs_cluster_name`."
  }

  assert {
    condition     = !strcontains(file("${path.module}/.github/workflows/deploy.yml"), "nginx-service")
    error_message = "De workflow bevat de servicenaam als hardcoded string. Haal hem op via `terraform output -raw ecs_service_name`."
  }

  # De IAM-rollen die de workflow nodig heeft (PowerUserAccess + IAM-beheer
  # voor de rollen in deze stack + lees/schrijfrechten op de state-bucket)
  # zitten in de IAM-user github-actions-deploy, buiten deze stack. Zie
  # README.md voor de exacte policy; hier controleren we dat de workflow daar
  # ook echt naar verwijst.
  assert {
    condition     = !strcontains(file("${path.module}/.github/workflows/deploy.yml"), "491799435972:role/")
    error_message = "De workflow verwijst naar een vastgezet rol-ARN. Die rollen horen in een IAM-user buiten Terraform, zodat de git-repo de enige bron van waarheid blijft."
  }
}

run "de_workflow_runt_eerst_tests_voordat_er_iets_naar_aws_gaat" {
  command = plan

  # REQ-NCA-P1-07: "een push naar de main branch triggert automatisch tests".
  # In de oude versie stopte de pipeline na 'terraform validate'.
  assert {
    condition     = strcontains(file("${path.module}/.github/workflows/deploy.yml"), "terraform test")
    error_message = "De workflow voert 'terraform test' niet uit; de assertions in tests/ worden dus nooit gecontroleerd."
  }

  assert {
    condition     = strcontains(file("${path.module}/.github/workflows/deploy.yml"), "terraform fmt -check")
    error_message = "De workflow controleert de code-opmaak niet."
  }

  # De deploy-job mag pas lopen als de plan-job (en dus de tests) geslaagd is.
  assert {
    condition     = strcontains(file("${path.module}/.github/workflows/deploy.yml"), "needs: plan")
    error_message = "De deploy-job hangt niet af van de plan-job; dan kan er gedeployed worden terwijl de tests nog falen."
  }

  # En de pipeline draait nog op GitHub-gehoste runners. Zolang de
  # self-hosted runner niet geregistreerd is, zou 'runs-on: [self-hosted]'
  # de uitrol stil laten liggen.
  assert {
    condition     = strcontains(file("${path.module}/.github/workflows/deploy.yml"), "runs-on: ubuntu-latest")
    error_message = "De workflow draait niet meer op een GitHub-gehoste runner. Zet 'runs-on: [self-hosted, linux]' pas om als de runner geregistreerd en online is."
  }
}
