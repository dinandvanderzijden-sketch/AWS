output "alb_dns_name" {
  value = aws_lb.this.dns_name
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "ecs_service_name" {
  value = aws_ecs_service.nginx.name
}

output "codedeploy_app_name" {
  value = aws_codedeploy_app.nginx.name
}

output "codedeploy_deployment_group" {
  value = aws_codedeploy_deployment_group.nginx.deployment_group_name
}
