# ============================================================
# ECR + ALB + Target Groups (Blue/Green)
# ============================================================
resource "aws_ecr_repository" "app" {
  name                 = "nginx-app"
  image_tag_mutability = "MUTABLE"
}

resource "aws_lb" "external_alb" {
  name               = "hub-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [aws_subnet.hub_public_a.id, aws_subnet.hub_public_b.id]
}

resource "aws_lb_target_group" "blue" {
  name        = "ecs-nginx-tg-blue"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.hub.id
  target_type = "ip"

  health_check {
    path                = "/healthz"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }
}

resource "aws_lb_target_group" "green" {
  name        = "ecs-nginx-tg-green"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.hub.id
  target_type = "ip"

  health_check {
    path                = "/healthz"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.external_alb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.blue.arn
  }

  # MIGRATIE: lifecycle-block hieronder is bewust UIT voor deze apply, zodat
  # Terraform de listener nu daadwerkelijk naar de blue target group mag zetten
  # (dat kon niet met ignore_changes aan, want de listener bestond al en wees
  # nog naar de oude, inmiddels verwijderde target group). Zodra deze apply
  # succesvol is afgerond: zet het blok hieronder terug aan en run nog een keer
  # `terraform apply` (dat levert dan geen wijzigingen meer op) zodat
  # CodeDeploy vanaf nu ongestoord blue/green-swaps kan doen.
  #
  # lifecycle {
  #   ignore_changes = [default_action]
  # }
}

# ============================================================
# ECS Cluster (Container Insights aan = echte CloudWatch metrics)
# ============================================================
resource "aws_ecs_cluster" "main" {
  name = "production-ecs-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

# ============================================================
# IAM
# ============================================================
resource "aws_iam_role" "ecs_execution_role" {
  name = "production-ecs-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_execution_policy" {
  role       = aws_iam_role.ecs_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# De Execution Role heeft secretsmanager:GetSecretValue nodig: dit is wat de
# "secrets" block in de task definition tijdens het opstarten injecteert.
resource "aws_iam_role_policy" "ecs_execution_secrets" {
  name = "ecs-execution-read-db-secret"
  role = aws_iam_role.ecs_execution_role.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [aws_secretsmanager_secret.db_credentials.arn]
    }]
  })
}

# Task Role: least-privilege leestoegang voor de applicatie zelf
resource "aws_iam_role" "ecs_task_role" {
  name = "production-ecs-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "ecs_task_secrets_read" {
  name = "ecs-task-read-db-secret"
  role = aws_iam_role.ecs_task_role.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [aws_secretsmanager_secret.db_credentials.arn]
    }]
  })
}

resource "aws_cloudwatch_log_group" "nginx" {
  name              = "/ecs/nginx-task"
  retention_in_days = 14
}

# ============================================================
# Cloud Map service discovery - zodat Prometheus de NGINX-taken kan vinden
# (Fargate-IP's zijn dynamisch, dit geeft een stabiele DNS-naam)
# ============================================================
resource "aws_service_discovery_private_dns_namespace" "internal" {
  name        = "internal.local"
  description = "Service discovery voor Spoke-Web"
  vpc         = aws_vpc.spoke_web.id
}

resource "aws_service_discovery_service" "web" {
  name = "web"

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.internal.id
    dns_records {
      ttl  = 10
      type = "A"
    }
    routing_policy = "MULTIVALUE"
  }

  health_check_custom_config {
    failure_threshold = 1
  }
}

# ============================================================
# ECS Task Definition & Service - NGINX op Fargate, Blue/Green via CodeDeploy
# ============================================================
resource "aws_ecs_task_definition" "nginx" {
  family                   = "nginx-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn

  container_definitions = jsonencode([
    {
      name         = "nginx"
      image        = "${aws_ecr_repository.app.repository_url}:latest"
      essential    = true
      portMappings = [{ containerPort = 80, hostPort = 80 }]
      secrets = [
        { name = "DB_PASSWORD", valueFrom = "${aws_secretsmanager_secret.db_credentials.arn}:password::" },
        { name = "DB_USERNAME", valueFrom = "${aws_secretsmanager_secret.db_credentials.arn}:username::" }
      ]
      environment = [
        { name = "DB_HOST", value = aws_db_instance.mariadb.address },
        { name = "DB_NAME", value = aws_db_instance.mariadb.db_name }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.nginx.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "nginx"
        }
      }
    },
    {
      name         = "nginx-exporter"
      image        = "nginx/nginx-prometheus-exporter:1.1.0"
      essential    = false
      command      = ["--nginx.scrape-uri=http://localhost:80/nginx_status"]
      portMappings = [{ containerPort = 9113, hostPort = 9113 }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.nginx.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "nginx-exporter"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "web" {
  name            = "nginx-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.nginx.arn
  desired_count   = 2 # minimaal 2 taken, verspreid over 2 AZ's (HA-eis uit het ontwerp)
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = [aws_subnet.web_private_a.id, aws_subnet.web_private_b.id]
    security_groups  = [aws_security_group.web_sg.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.blue.arn
    container_name   = "nginx"
    container_port   = 80
  }

  service_registries {
    registry_arn = aws_service_discovery_service.web.arn
  }

  deployment_controller {
    type = "CODE_DEPLOY"
  }

  # Na de eerste deploy neemt CodeDeploy task_definition en target group over
  lifecycle {
    ignore_changes = [task_definition, load_balancer]
  }

  depends_on = [aws_lb_listener.http]
}

# ============================================================
# Auto Scaling - stapsgewijs, met de exacte drempels uit het ontwerpdocument:
# >70% CPU gedurende 5 min -> +2 taken; <20% CPU gedurende 10 min -> -2 taken
# ============================================================
resource "aws_appautoscaling_target" "ecs_target" {
  max_capacity       = 4
  min_capacity       = 2
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.web.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "scale_out" {
  name               = "scale-out-cpu-high"
  policy_type        = "StepScaling"
  resource_id        = aws_appautoscaling_target.ecs_target.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_target.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_target.service_namespace

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 300
    metric_aggregation_type = "Average"
    step_adjustment {
      scaling_adjustment          = 2
      metric_interval_lower_bound = 0
    }
  }
}

resource "aws_appautoscaling_policy" "scale_in" {
  name               = "scale-in-cpu-low"
  policy_type        = "StepScaling"
  resource_id        = aws_appautoscaling_target.ecs_target.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_target.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_target.service_namespace

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 600
    metric_aggregation_type = "Average"
    step_adjustment {
      scaling_adjustment           = -2
      metric_interval_upper_bound  = 0
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "ecs-cpu-high-scale-out"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 5 # 5x 1 minuut = 5 minuten boven 70%
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = 70
  alarm_actions       = [aws_appautoscaling_policy.scale_out.arn]
  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = aws_ecs_service.web.name
  }
}

resource "aws_cloudwatch_metric_alarm" "cpu_low" {
  alarm_name          = "ecs-cpu-low-scale-in"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 10 # 10x 1 minuut = 10 minuten onder 20%
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = 20
  alarm_actions       = [aws_appautoscaling_policy.scale_in.arn]
  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = aws_ecs_service.web.name
  }
}
