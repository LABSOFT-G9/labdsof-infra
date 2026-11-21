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
  # Fixed address of the application host in the private subnet (10.x.1.0/24),
  # known before it exists, so the edge host does not wait for it.
  app_private_ip = cidrhost(cidrsubnet(var.vpc_cidr, 8, 1), 10)
}

module "network" {
  source = "../../modules/network"

  name       = local.name
  region     = var.region
  cidr_block = var.vpc_cidr
}

module "edge" {
  source = "../../modules/edge"

  name                   = local.name
  instance_type          = var.edge_instance_type
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

  name                 = local.name
  instance_type        = var.app_instance_type
  architecture         = var.app_architecture
  vpc_id               = module.network.vpc_id
  vpc_cidr             = var.vpc_cidr
  subnet_id            = module.network.private_subnet_id
  private_ip           = local.app_private_ip
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
  availability_zone         = module.network.availability_zone
  data_volume_size          = var.database_volume_size
  deletion_protection       = var.deletion_protection
  client_security_group_ids = module.app[*].security_group_id
  backups_bucket            = module.storage.backups_bucket
  backups_bucket_arn        = module.storage.backups_bucket_arn
  permissions_boundary      = local.workload_boundary_arn
}
