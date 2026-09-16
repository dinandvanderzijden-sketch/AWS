output "alb_dns_name" {
  description = "Publiek endpoint van de applicatie."
  value       = module.compute.alb_dns_name
}

output "db_endpoint" {
  value     = module.database.db_endpoint
  sensitive = true
}

output "ecs_cluster_name" {
  value = module.compute.ecs_cluster_name
}

output "codedeploy_app_name" {
  value = module.compute.codedeploy_app_name
}

output "runner_private_ip" {
  value = module.cicd.runner_private_ip
}

output "observability_private_ip" {
  description = "Bereik Grafana via VPN/Bastion op <ip>:3000."
  value       = module.observability.instance_private_ip
}
