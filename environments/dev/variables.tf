variable "environment" {
  type = string
}

variable "region" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "edge_instance_type" {
  description = "Edge host (NAT and web forwarding); arm64, for example t4g.nano."
  type        = string
}

variable "app_enabled" {
  description = "Create the application host."
  type        = bool
}

variable "app_instance_type" {
  description = "Application host instance type."
  type        = string
}

variable "app_architecture" {
  description = "arm64 or x86_64; must match app_instance_type."
  type        = string
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
