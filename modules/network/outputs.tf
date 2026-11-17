output "vpc_id" {
  value = aws_vpc.this.id
}

output "public_subnet_id" {
  value = aws_subnet.public.id
}

output "private_subnet_id" {
  value = aws_subnet.private.id
}

output "availability_zone" {
  description = "Zone of both subnets; volumes attached to hosts here must use it."
  value       = local.az
}
