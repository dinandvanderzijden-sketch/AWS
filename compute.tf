# =============================================================================
# compute.tf — ALB + NGINX op ECS Fargate.
#
# Vereenvoudigingen t.o.v. een "volledige" opzet:
#  - Gewone ALB (geen Network Load Balancer nodig, want ALB en ECS-taken
#    zitten nu in dezelfde VPC).
#  - Standaard ECS rolling-update deployment (minimum 100% / maximum 200%
#    gezond) in plaats van CodeDeploy blue/green. Dit is nog steeds
#    zero-downtime — je wisselt alleen niet in één klap van target group.
#    Blue/green kun je er later bij zetten als de klant dat écht eist.
#  - Eén target-tracking autoscaling-policy (CPU 70%) in plaats van losse
#    CloudWatch-alarms + step-scaling policies.
# =============================================================================

resource "aws_lb" "this" {
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  tags = { Name = "${var.project_name}-alb" }
}

resource "aws_lb_target_group" "this" {
  name        = "${var.project_name}-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.this.id
  target_type = "ip"

  health_check {
    path                = "/healthz"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 15
    timeout             = 5
  }

  tags = { Name = "${var.project_name}-tg" }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}

# --- ECS cluster + logging --------------------------------------------------

resource "aws_ecs_cluster" "this" {
  name = "${var.project_name}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}

resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${var.project_name}-nginx"
  retention_in_days = 30
}

# --- IAM: execution role (pull image, schrijf logs) + task role (least priv)

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_execution" {
  name               = "${var.project_name}-ecs-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "ecs_task" {
  name               = "${var.project_name}-ecs-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

# De applicatie mag ALLEEN het eigen DB-secret lezen — verder niets.
resource "aws_iam_role_policy" "ecs_task_secrets" {
  name = "${var.project_name}-ecs-task-secrets-read"
  role = aws_iam_role.ecs_task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = aws_secretsmanager_secret.db.arn
    }]
  })
}

# --- Task definitie + service ------------------------------------------------

resource "aws_ecs_task_definition" "nginx" {
  family                   = "${var.project_name}-nginx"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.ecs_task_cpu
  memory                   = var.ecs_task_memory
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    {
      name      = "nginx"
      image     = var.container_image
      essential = true
      portMappings = [
        { containerPort = 80, protocol = "tcp" }
      ]
      secrets = [
        { name = "DB_CREDENTIALS", valueFrom = aws_secretsmanager_secret.db.arn }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "nginx"
        }
      }
    }
  ])

  tags = { Name = "${var.project_name}-nginx-taskdef" }
}

resource "aws_ecs_service" "nginx" {
  name            = "${var.project_name}-nginx-svc"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.nginx.arn
  desired_count   = var.ecs_min_tasks

  capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }

  network_configuration {
    subnets          = aws_subnet.private_web[*].id
    security_groups  = [aws_security_group.web.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.this.arn
    container_name    = "nginx"
    container_port    = 80
  }

  # Standaard ECS rolling-update: nooit minder dan 100% gezonde taken, tot
  # maximaal 200% tijdens een deploy — dus altijd zero-downtime.
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent          = 200

  depends_on = [aws_lb_listener.http]
}

# --- Autoscaling: één target-tracking policy op CPU --------------------------

resource "aws_appautoscaling_target" "nginx" {
  max_capacity       = var.ecs_max_tasks
  min_capacity       = var.ecs_min_tasks
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.nginx.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "${var.project_name}-cpu-target-tracking"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.nginx.resource_id
  scalable_dimension = aws_appautoscaling_target.nginx.scalable_dimension
  service_namespace  = aws_appautoscaling_target.nginx.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = var.ecs_cpu_target
    scale_in_cooldown  = 120
    scale_out_cooldown = 60
  }
}
