output "runner_instance_id" {
  value = aws_instance.runner.id
}

output "runner_private_ip" {
  value = aws_instance.runner.private_ip
}
