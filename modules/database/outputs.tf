output "db_endpoint" {
  value = aws_db_instance.this.address
}

output "db_secret_arn" {
  description = "ARN van de Secrets Manager entry — ECS Task Role krijgt hier alleen leesrechten op."
  value       = aws_secretsmanager_secret.db.arn
}

output "db_instance_id" {
  value = aws_db_instance.this.id
}
