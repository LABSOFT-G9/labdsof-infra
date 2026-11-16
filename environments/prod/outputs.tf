output "database_private_ip" {
  value = module.database.private_ip
}

output "database_instance_id" {
  description = "For SSM Session Manager: aws ssm start-session --target <id>"
  value       = module.database.instance_id
}

output "database_ami_id" {
  value = module.database.ami_id
}

output "database_parameter_prefix" {
  description = "Create the database secrets here before the first apply (docs/runbooks/database.md)."
  value       = module.database.parameter_prefix
}

output "attachments_bucket" {
  value = module.storage.attachments_bucket
}

output "backups_bucket" {
  value = module.storage.backups_bucket
}

output "app_security_group_id" {
  value = aws_security_group.app.id
}
