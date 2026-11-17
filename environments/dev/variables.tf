variable "environment" {
  type = string
}

variable "region" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "database_enabled" {
  description = "Create the database host. Needs a bmc-database AMI to exist."
  type        = bool
}

variable "database_ami_version" {
  description = "bmc-database AMI version; \"*\" = newest build."
  type        = string
}

variable "database_instance_type" {
  type = string
}

variable "database_volume_size" {
  description = "MySQL data volume in GiB."
  type        = number
}

variable "database_in_private_subnet" {
  description = "Private subnet plus SSM interface endpoints (billed per hour), or public subnet with an outbound-only public IP."
  type        = bool
}

variable "deletion_protection" {
  type = bool
}

variable "backup_retention_days" {
  type = number
}

variable "backup_lock_days" {
  description = "Object Lock on backups in days; 0 = off. Must be decided before the bucket is created."
  type        = number
}

variable "force_destroy_buckets" {
  description = "Let terraform destroy delete non-empty buckets."
  type        = bool
}
