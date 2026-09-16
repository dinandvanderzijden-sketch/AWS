output "alb_sg_id" {
  value = aws_security_group.alb.id
}

output "web_sg_id" {
  value = aws_security_group.web.id
}

output "database_sg_id" {
  value = aws_security_group.database.id
}

output "management_sg_id" {
  value = aws_security_group.management.id
}
