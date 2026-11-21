output "vpc_id" {
  description = "The environment's VPC."
  value       = aws_vpc.this.id
}

output "public_subnet_id" {
  description = "Public subnet: the edge host only."
  value       = aws_subnet.public.id
}

output "private_subnet_id" {
  description = "Private subnet: every host except the edge host."
  value       = aws_subnet.private.id
}

output "private_subnet_cidr" {
  description = "Address range of the private subnet; the edge host NATs it."
  value       = aws_subnet.private.cidr_block
}

output "private_route_table_id" {
  description = "For the edge host's NAT route."
  value       = aws_route_table.private.id
}
