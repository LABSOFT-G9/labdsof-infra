output "public_ip" {
  description = "Fixed public address (Elastic IP): point DNS here."
  value       = aws_eip.edge.public_ip
}

output "private_ip" {
  value = aws_instance.edge.private_ip
}

output "instance_id" {
  description = "For SSM Session Manager: aws ssm start-session --target <id>"
  value       = aws_instance.edge.id
}

output "security_group_id" {
  value = aws_security_group.edge.id
}
