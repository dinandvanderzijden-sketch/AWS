# ============================================================
# Alarms & notificatie - REQ-NCA-P1-05
#
# Acceptatiecriterium: "Een overschrijding van kritieke drempelwaarden
# triggert binnen 1 minuut een notificatie."
#
# In de oude staat van de code hingen de twee CPU-alarms uitsluitend aan het
# autoscaling-beleid (compute.tf): die schalen op en af, maar er ging nooit
# een melding naar een mens. En de vier overige metrieken uit de tabel
# "Onderbouwing Monitorde Metrieken & Drempeloverschrijdingen" bestonden
# helemaal niet.
#
# Dit bestand maakt dat notificatiepad expliciet: elk kritiek alarm heeft een
# 'evaluation_periods' van 1 x 60 seconden, dus detectie binnen 1 minuut. Alle
# alarms hangen aan dezelfde SNS-topic.
#
# WAAROM CLOUDWATCH-ALARMS EN NIET PROMETHEUS ALERTMANAGER / GRAFANA ALERTING
#   - geen extra bestaand onderdeel nodig (geen SMTP, geen relay)
#   - ze overleven een reboot van de monitoring-instance
#   - ze sluiten aan op dezelfde metrieken als het dashboard, dus een drempel
#     in het dashboard en een drempel in een alarm lopen nooit uit elkaar
#     (tests/observability.tftest.hcl controleert dat ook echt)
# ============================================================

# ------------------------------------------------------------
# SNS: het notificatiekanaal
# ------------------------------------------------------------
resource "aws_sns_topic" "alerts" {
  name = "nca-infra-alerts"
  tags = { Name = "nca-infra-alerts" }
}

resource "aws_sns_topic_subscription" "email" {
  count = var.alert_email == "" ? 0 : 1

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ------------------------------------------------------------
# Rekenregel voor het ALB-5xx-foutpercentage.
# CloudWatch kan geen ratio tussen twee bestaande metrics rekenen zonder
# metric math, dus die schrijven we hier als expliciete expressie uit.
# IF(..., ..., 0) voorkomt een deling door nul als er geen verkeer is.
# ------------------------------------------------------------
locals {
  alb_5xx_expression = "IF(requests > 0, (err5xx / requests) * 100, 0)"
}

# ------------------------------------------------------------
# 1. HTTP 5xx Error Rate > 1% van het totale verkeer (1 minuut)
#    "Primaire indicator voor applicatiestoringen; stuurt directe notificatie."
# ------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "alb_5xx_rate" {
  alarm_name          = "alb-5xx-error-rate-high"
  alarm_description   = "Meer dan 1% van het verkeer over de ALB levert een 5xx op. Drempel uit het ontwerpdocument (REQ-NCA-P1-05)."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  metric_query {
    id          = "err5xx"
    return_data = false
    metric {
      metric_name = "HTTPCode_Target_5XX_Count"
      namespace   = "AWS/ApplicationELB"
      period      = 60
      stat        = "Sum"
      dimensions = {
        LoadBalancer = aws_lb.external_alb.arn_suffix
      }
    }
  }

  metric_query {
    id          = "requests"
    return_data = false
    metric {
      metric_name = "RequestCount"
      namespace   = "AWS/ApplicationELB"
      period      = 60
      stat        = "Sum"
      dimensions = {
        LoadBalancer = aws_lb.external_alb.arn_suffix
      }
    }
  }

  metric_query {
    id          = "rate"
    expression  = local.alb_5xx_expression
    label       = "5xx als % van totaal"
    return_data = true
  }
}

# ------------------------------------------------------------
# 2. Latency: TargetResponseTime > 500ms gemiddeld
#    "Bewaakt de gebruikerservaring en helpt bij het opsporen van knelpunten
#    in de datalaag."
#
#    AFWIJKING VAN HET ONTWERPDOCUMENT: dat noemt "gemiddeld over 3 minuten".
#    Het acceptatiecriterium is strenger - "triggert binnen 1 minuut een
#    notificatie" - en met 3 evaluatieperiodes zit je al minstens 3 minuten
#    over de drempel. Daarom 1 periode van 60 seconden. De prijs is een valse
#    melding bij een korte uitschieter; dat weegt hier lichter dan een melding
#    die te laat komt.
# ------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "alb_latency" {
  alarm_name          = "alb-target-response-time-high"
  alarm_description   = "Gemiddelde responstijd van het doelwit ligt boven 500ms. Drempel uit het ontwerpdocument (REQ-NCA-P1-05)."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 0.5
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  metric_query {
    id          = "latency"
    return_data = true
    metric {
      metric_name = "TargetResponseTime"
      namespace   = "AWS/ApplicationELB"
      period      = 60
      stat        = "Average"
      dimensions = {
        LoadBalancer = aws_lb.external_alb.arn_suffix
      }
    }
  }
}

# ------------------------------------------------------------
# 3. Geheugen: > 80% van de container limit
#    "Voorkomt Out-Of-Memory (OOM) crashes op NGINX-taken."
#    Bron is Container Insights; dat staat aan in compute.tf.
# ------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "ecs_memory" {
  alarm_name          = "ecs-memory-utilization-high"
  alarm_description   = "Geheugengebruik van de NGINX-taken boven 80% van de container limit. Drempel uit het ontwerpdocument (REQ-NCA-P1-05)."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 80
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  metric_query {
    id          = "mem"
    return_data = true
    metric {
      metric_name = "memory_utilization"
      namespace   = "ECS/ContainerInsights"
      period      = 60
      stat        = "Average"
      dimensions = {
        ClusterName = aws_ecs_cluster.main.name
        ServiceName = aws_ecs_service.web.name
      }
    }
  }
}

# ------------------------------------------------------------
# 4. Database: CPU > 85%
#    "Bepaalt wanneer de database-instance verticaal moet worden opgeschaald."
#
#    Zelfde afwijking als bij de latency-alarm: het ontwerpdocument noemt "5
#    minuten", het acceptatiecriterium eist een notificatie binnen 1 minuut.
#    De database is bovendien de traagste laag om op te schalen, dus een
#    vroege melding is hier meer waard dan een late. ------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name          = "rds-mariadb-cpu-high"
  alarm_description   = "CPU-belasting van de MariaDB-instance boven 85%. Drempel uit het ontwerpdocument (REQ-NCA-P1-05)."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 85
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  metric_query {
    id          = "cpu"
    return_data = true
    metric {
      metric_name = "CPUUtilization"
      namespace   = "AWS/RDS"
      period      = 60
      stat        = "Average"
      dimensions = {
        DBInstanceIdentifier = aws_db_instance.mariadb.identifier
      }
    }
  }
}

# ------------------------------------------------------------
# 5. HA: minder gezonde targets dan het minimum aantal taken.
#
#    Dit alarm stond niet in het ontwerpdocument, maar is de directe
#    bewijsvoering voor het "nultolerantie voor downtime"-criterium van
#    REQ-NCA-P1-04. Zonder dit alarm merk je een uitgevallen taak pas doordat
#    gebruikers iets zien.
#
#    WAAROM ALLEEN DE DIMENSION "LoadBalancer" EN GEEN "TargetGroup"?
#    Met een TargetGroup-dimension meet je één specifieke group. Bij blue/green
#    zou dat de group zijn die op dat moment toevallig actueel is, en zodra
#    CodeDeploy naar green schakelt meet het alarm een group die níet meer
#    verkeer krijgt. Dat is een vals alarm dat de bewaker onbruikbaar maakt.
#
#    Zonder de TargetGroup-dimension telt CloudWatch over álle target groups
#    van de ALB, en met stat = "Minimum" krijg je het zwakste van die waarden.
#    Na een blue/green-switch blijft het alarm dus correct werken zonder dat er
#    iets herzien hoeft te worden.
#
#    evaluation_periods is hier 2 in plaats van 1: tijdens het opstarten van
#    green is die group kortstondig niet gezond, en dat is een normale stap in
#    de deployment, geen storing.
# ------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "alb_unhealthy" {
  alarm_name          = "alb-healthy-hosts-below-minimum"
  alarm_description   = "Er draaien minder gezonde NGINX-taken dan het minimum van 2 (de HA-eis van REQ-NCA-P1-04), in welke target group dan ook."
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  threshold           = 2
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  metric_query {
    id          = "healthy"
    return_data = true
    metric {
      metric_name = "HealthyHostCount"
      namespace   = "AWS/ApplicationELB"
      period      = 60
      stat        = "Minimum"
      # Bewust zonder TargetGroup: zie de toelichting hierboven.
      dimensions = {
        LoadBalancer = aws_lb.external_alb.arn_suffix
      }
    }
  }
}
