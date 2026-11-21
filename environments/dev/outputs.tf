output "database_private_ip" {
  value = one(module.database[*].private_ip)
}

output "database_instance_id" {
  description = "For SSM Session Manager: aws ssm start-session --target <id>"
  value       = one(module.database[*].instance_id)
}

output "database_ami_id" {
  value = one(module.database[*].ami_id)
}

output "database_parameter_prefix" {
  description = "Create the database secrets here before the first apply (docs/runbooks/database.md)."
  value       = one(module.database[*].parameter_prefix)
}

output "attachments_bucket" {
  value = module.storage.attachments_bucket
}

output "backups_bucket" {
  value = module.storage.backups_bucket
}

output "edge_public_ip" {
  description = "Fixed public address of the edge host: point DNS here."
  value       = module.edge.public_ip
}

output "edge_instance_id" {
  description = "For SSM Session Manager: aws ssm start-session --target <id>"
  value       = module.edge.instance_id
}

output "app_private_ip" {
  value = one(module.app[*].private_ip)
}

output "app_instance_id" {
  description = "For SSM Session Manager: aws ssm start-session --target <id>"
  value       = one(module.app[*].instance_id)
}

output "monitoring_private_ip" {
  value = one(module.monitoring[*].private_ip)
}

output "monitoring_instance_id" {
  description = "For SSM Session Manager (and port forwarding to Grafana): aws ssm start-session --target <id>"
  value       = one(module.monitoring[*].instance_id)
}
