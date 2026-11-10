output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets, in availability zone order."
  value       = [for az in var.availability_zones : aws_subnet.public[az].id]
}

output "private_subnet_ids" {
  description = "IDs of the private subnets, in availability zone order."
  value       = [for az in var.availability_zones : aws_subnet.private[az].id]
}

output "nat_gateway_public_ip" {
  description = "Public IP of the NAT gateway (egress IP of the worker nodes)."
  value       = aws_eip.nat.public_ip
}
