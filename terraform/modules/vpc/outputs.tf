output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.main.id
}

output "vpc_cidr_block" {
  description = "CIDR block of the VPC"
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_ids" {
  description = "IDs of the public subnets (load balancers only)"
  value       = aws_subnet.public[*].id
}

# output "private_subnet_ids" — disabled for dev (private subnets commented out)
# output "private_subnet_ids" {
#   description = "IDs of the private subnets (EKS worker nodes and internal services)"
#   value       = aws_subnet.private[*].id
# }

# output "nat_gateway_id" — disabled for dev (NAT Gateway commented out)
# output "nat_gateway_id" {
#   description = "ID of the single NAT Gateway"
#   value       = aws_nat_gateway.main.id
# }
#
# output "nat_gateway_public_ip" {
#   description = "Public Elastic IP address of the NAT Gateway"
#   value       = aws_eip.nat.public_ip
# }

output "internet_gateway_id" {
  description = "ID of the Internet Gateway"
  value       = aws_internet_gateway.main.id
}

output "public_route_table_id" {
  description = "ID of the public route table"
  value       = aws_route_table.public.id
}

# output "private_route_table_id" — disabled for dev (private route table commented out)
# output "private_route_table_id" {
#   description = "ID of the private route table"
#   value       = aws_route_table.private.id
# }

output "flow_log_group_name" {
  description = "CloudWatch log group name for VPC flow logs"
  value       = aws_cloudwatch_log_group.vpc_flow_logs.name
}

output "flow_log_group_arn" {
  description = "CloudWatch log group ARN for VPC flow logs"
  value       = aws_cloudwatch_log_group.vpc_flow_logs.arn
}
