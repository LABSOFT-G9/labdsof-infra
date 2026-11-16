# The same internal modules for every environment; only the values in
# terraform.tfvars differ (see README "Environments").

locals {
  name = "bmc-${var.environment}"
}

module "network" {
  source = "../../modules/network"

  name                 = local.name
  region               = var.region
  cidr_block           = var.vpc_cidr
  enable_ssm_endpoints = var.database_in_private_subnet
}

module "storage" {
  source = "../../modules/storage"

  name                  = local.name
  backup_retention_days = var.backup_retention_days
  backup_lock_days      = var.backup_lock_days
  force_destroy         = var.force_destroy_buckets
}

# Placeholder for the application host (US-17). The database only accepts
# MySQL from this group; the app host joins it when it is added.
resource "aws_security_group" "app" {
  name        = "${local.name}-app"
  description = "Application host"
  vpc_id      = module.network.vpc_id

  tags = { Name = "${local.name}-app" }
}

module "database" {
  source = "../../modules/database"

  name                      = local.name
  environment               = var.environment
  ami_version               = var.database_ami_version
  instance_type             = var.database_instance_type
  vpc_id                    = module.network.vpc_id
  subnet_id                 = var.database_in_private_subnet ? module.network.private_subnet_id : module.network.public_subnet_id
  availability_zone         = module.network.availability_zone
  public_ip                 = !var.database_in_private_subnet
  data_volume_size          = var.database_volume_size
  deletion_protection       = var.deletion_protection
  client_security_group_ids = [aws_security_group.app.id]
  backups_bucket            = module.storage.backups_bucket
  backups_bucket_arn        = module.storage.backups_bucket_arn
}
