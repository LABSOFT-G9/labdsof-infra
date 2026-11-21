output "vpc_id" {
  value = aws_vpc.this.id
}

output "public_subnet_id" {
  value = aws_subnet.public.id
}

output "private_subnet_id" {
  value = aws_subnet.private.id
}

output "private_subnet_cidr" {
  value = aws_subnet.private.cidr_block
}

output "private_route_table_id" {
  description = "For the edge host's NAT route."
  value       = aws_route_table.private.id
}

output "availability_zone" {
  description = "Zone of both subnets; volumes attached to hosts here must use it."
  value       = local.az
}
