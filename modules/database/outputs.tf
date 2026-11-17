output "instance_id" {
  value = aws_instance.database.id
}

output "private_ip" {
  description = "Address the application host uses for MySQL."
  value       = aws_instance.database.private_ip
}

output "security_group_id" {
  value = aws_security_group.database.id
}

output "ami_id" {
  description = "The AMI the host runs."
  value       = data.aws_ami.database.id
}

output "parameter_prefix" {
  description = "SSM Parameter Store path for this database's secrets."
  value       = local.parameter_prefix
}
