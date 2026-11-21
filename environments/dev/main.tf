# The same internal modules for every environment; only the values in
# terraform.tfvars differ (see README "Environments").
#
# Network (README "Network"): the edge host is the only host in the public
# subnet; every other host is in the private subnet and reaches the internet
# through the edge host's NAT.

data "aws_caller_identity" "current" {}

locals {
  name = "bmc-${var.environment}"
  # Created by bootstrap/; every workload role must carry it.
  workload_boundary_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/bmc-workload-boundary"
  # Fixed addresses in the private subnet (10.x.1.0/24), known before the
  # hosts exist, so the hosts that point at them do not wait for them.
  app_private_ip        = cidrhost(cidrsubnet(var.vpc_cidr, 8, 1), 10)
  monitoring_private_ip = cidrhost(cidrsubnet(var.vpc_cidr, 8, 1), 20)
  database_private_ip   = cidrhost(cidrsubnet(var.vpc_cidr, 8, 1), 30)
  monitoring_ip         = var.monitoring_enabled ? local.monitoring_private_ip : null
}

module "network" {
  source = "../../modules/network"

  name              = local.name
  region            = var.region
  cidr_block        = var.vpc_cidr
  availability_zone = var.availability_zone
}

module "edge" {
  source = "../../modules/edge"

  name                   = local.name
  instance_type          = var.edge_instance_type
  ami_id                 = var.edge_ami_id
  vpc_id                 = module.network.vpc_id
  vpc_cidr               = var.vpc_cidr
  subnet_id              = module.network.public_subnet_id
  private_cidrs          = [module.network.private_subnet_cidr]
  private_route_table_id = module.network.private_route_table_id
  # 80/443 go to the application host; without it the edge host only does
  # NAT and keeps 80/443 closed.
  forward_to_ip        = var.app_enabled ? local.app_private_ip : null
  permissions_boundary = local.workload_boundary_arn
}

# Plain host for now: no software added yet.
module "app" {
  source = "../../modules/app"
  count  = var.app_enabled ? 1 : 0

  name          = local.name
  instance_type = var.app_instance_type
  ami_id        = var.app_ami_id
  vpc_id        = module.network.vpc_id
  subnet_id     = module.network.private_subnet_id
  private_ip    = local.app_private_ip
  database_ip   = var.database_enabled ? local.database_private_ip : null
  monitoring_ip = local.monitoring_ip
  # Uploads (for example photos) go to the attachments bucket.
  attachments_bucket_arn = module.storage.attachments_bucket_arn
  parameter_prefix       = "/bmc/${var.environment}/app"
  # The services' database passwords (not root, backup or exporter).
  database_users_parameter_path = var.database_enabled ? "/bmc/${var.environment}/database/users" : null
  deletion_protection           = var.deletion_protection
  permissions_boundary          = local.workload_boundary_arn
}

# Prometheus, Loki and Grafana (ansible/roles/monitoring). The edge,
# application and database hosts push metrics and logs to it.
module "monitoring" {
  source = "../../modules/monitoring"
  count  = var.monitoring_enabled ? 1 : 0

  name          = local.name
  instance_type = var.monitoring_instance_type
  ami_id        = var.monitoring_ami_id
  vpc_id        = module.network.vpc_id
  subnet_id     = module.network.private_subnet_id
  private_ip    = local.monitoring_private_ip
  # Its secrets, for example the Grafana admin password.
  parameter_prefix = "/bmc/${var.environment}/monitoring"
  # Host name => security group, for the hosts that exist.
  client_security_group_ids = {
    for host, groups in {
      edge     = [module.edge.security_group_id]
      app      = module.app[*].security_group_id
      database = module.database[*].security_group_id
    } : host => groups[0] if length(groups) > 0
  }
  deletion_protection  = var.deletion_protection
  permissions_boundary = local.workload_boundary_arn
}

module "storage" {
  source = "../../modules/storage"

  name                  = local.name
  backup_retention_days = var.backup_retention_days
  backup_lock_days      = var.backup_lock_days
  force_destroy         = var.force_destroy_buckets
}

# Off until the first database AMI exists (ami/database).
module "database" {
  source = "../../modules/database"
  count  = var.database_enabled ? 1 : 0

  name                      = local.name
  environment               = var.environment
  ami_version               = var.database_ami_version
  instance_type             = var.database_instance_type
  vpc_id                    = module.network.vpc_id
  subnet_id                 = module.network.private_subnet_id
  private_ip                = local.database_private_ip
  data_volume_size          = var.database_volume_size
  deletion_protection       = var.deletion_protection
  client_security_group_ids = module.app[*].security_group_id
  # One database and one user per service (ADR-004).
  databases = var.databases
  # Agents push to the monitoring host; nothing scrapes the database host.
  monitoring_ip        = local.monitoring_ip
  backups_bucket       = module.storage.backups_bucket
  backups_bucket_arn   = module.storage.backups_bucket_arn
  permissions_boundary = local.workload_boundary_arn
}
