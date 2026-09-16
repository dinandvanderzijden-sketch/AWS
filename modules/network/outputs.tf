output "hub_vpc_id" {
  value = aws_vpc.hub.id
}

output "hub_public_subnet_ids" {
  value = aws_subnet.hub_public[*].id
}

output "hub_mgmt_subnet_id" {
  value = aws_subnet.hub_mgmt.id
}

output "spoke_web_vpc_id" {
  value = aws_vpc.spoke_web.id
}

output "spoke_web_subnet_ids" {
  value = aws_subnet.spoke_web[*].id
}

output "spoke_data_vpc_id" {
  value = aws_vpc.spoke_data.id
}

output "spoke_data_subnet_ids" {
  value = aws_subnet.spoke_data[*].id
}

output "azs" {
  value = local.azs
}
