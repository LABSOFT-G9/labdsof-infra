output "private_ip" {
  description = "The edge host forwards 80/443 here."
  value       = aws_instance.app.private_ip
}

output "instance_id" {
  description = "For SSM Session Manager: aws ssm start-session --target <id>"
  value       = aws_instance.app.id
}

output "security_group_id" {
  description = "The application host's security group: the database and monitoring hosts allow it."
  value       = aws_security_group.app.id
}
