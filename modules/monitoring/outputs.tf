output "private_ip" {
  description = "Where the other hosts push metrics (9090)."
  value       = aws_instance.monitoring.private_ip
}

output "instance_id" {
  description = "For SSM Session Manager (and port forwarding to Grafana): aws ssm start-session --target <id>"
  value       = aws_instance.monitoring.id
}

output "security_group_id" {
  description = "The monitoring host's security group."
  value       = aws_security_group.monitoring.id
}
