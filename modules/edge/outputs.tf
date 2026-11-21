output "public_ip" {
  description = "Current public address; it changes when the host is stopped and started."
  value       = aws_instance.edge.public_ip
}

output "private_ip" {
  description = "The edge host's address inside the VPC."
  value       = aws_instance.edge.private_ip
}

output "instance_id" {
  description = "For SSM Session Manager: aws ssm start-session --target <id>"
  value       = aws_instance.edge.id
}

output "security_group_id" {
  description = "The edge host's security group: the monitoring host allows it."
  value       = aws_security_group.edge.id
}
