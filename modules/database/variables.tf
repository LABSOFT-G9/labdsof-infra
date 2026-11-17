variable "name" {
  description = "Prefix for resource names, for example bmc-dev."
  type        = string
}

variable "environment" {
  description = "Environment name (dev or prod). Selects the SSM parameter path /bmc/<environment>/database."
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be dev or prod."
  }
}

variable "ami_version" {
  description = "AMI version to run (the image is bmc-database-<version>). \"*\" takes the newest build; pin an exact version where changes must be deliberate."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_id" {
  description = "Subnet for the host."
  type        = string
}

variable "availability_zone" {
  description = "Must be the subnet's availability zone, because the data volume is attached there."
  type        = string
}

variable "public_ip" {
  description = "Give the host a public IP for outbound traffic. Needed in a public subnet without VPC endpoints; inbound access is still limited by the security group."
  type        = bool
  default     = false
}

variable "data_volume_size" {
  description = "Size of the MySQL data volume in GiB."
  type        = number
}

variable "deletion_protection" {
  description = "Block terminating the instance through the API."
  type        = bool
  default     = false
}

variable "client_security_group_ids" {
  description = "Security groups allowed to connect to MySQL (3306), for example the application host."
  type        = list(string)
}

variable "monitoring_security_group_ids" {
  description = "Security groups allowed to scrape mysqld_exporter (9104)."
  type        = list(string)
  default     = []
}

variable "backups_bucket" {
  description = "Name of the backups bucket (modules/storage)."
  type        = string
}

variable "backups_bucket_arn" {
  description = "ARN of the backups bucket (modules/storage)."
  type        = string
}

variable "permissions_boundary" {
  description = "ARN of the IAM permissions boundary every workload role must carry (bootstrap output workload_boundary_arn)."
  type        = string
}

variable "backup_schedule" {
  description = "systemd OnCalendar expression for the nightly backup, in UTC."
  type        = string
  default     = "*-*-* 02:00:00"
}
