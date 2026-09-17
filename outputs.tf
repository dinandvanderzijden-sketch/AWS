output "alb_dns_name" {
  description = "Publiek endpoint van de applicatie."
  value       = aws_lb.this.dns_name
}

output "db_endpoint" {
  value     = aws_db_instance.this.address
  sensitive = true
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "ecs_service_name" {
  value = aws_ecs_service.nginx.name
}

output "runner_public_ip" {
  value = aws_instance.runner.public_ip
}

output "observability_public_ip" {
  description = "Bereik Grafana via <ip>:3000 (alleen toegestaan vanaf admin_cidr)."
  value       = aws_instance.observability.public_ip
}
