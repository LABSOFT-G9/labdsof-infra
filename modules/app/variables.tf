variable "name" {
  description = "Prefix for resource names, for example bmc-dev."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type; it decides the CPU architecture (t4g/m7g are arm64, t3/m7i are x86_64)."
  type        = string
}

variable "ami_id" {
  description = "Pinned image (AMI ID, region-specific). Its architecture must match instance_type; changing it replaces the host."
  type        = string

  validation {
    condition     = can(regex("^ami-[0-9a-f]{8,17}$", var.ami_id))
    error_message = "ami_id must look like ami-0123456789abcdef0."
  }
}

variable "vpc_id" {
  type = string
}

variable "subnet_id" {
  description = "Private subnet for the host."
  type        = string
}

variable "private_ip" {
  description = "Fixed private address in the subnet, so the edge host can forward to it without waiting for this host."
  type        = string
}

variable "root_volume_size" {
  description = "Root volume in GiB."
  type        = number
  default     = 30
}

variable "deletion_protection" {
  description = "Block terminating the instance through the API."
  type        = bool
  default     = false
}

variable "permissions_boundary" {
  description = "ARN of the IAM permissions boundary every workload role must carry (bootstrap policy bmc-workload-boundary)."
  type        = string
}

variable "database_ip" {
  description = "Private IP of the database host, to allow MySQL (3306) to it. Null: no database host."
  type        = string
  default     = null
}

variable "attachments_bucket_arn" {
  description = "ARN of the attachments bucket (modules/storage) the application reads and writes."
  type        = string
}

variable "cpu_credits" {
  description = "Credit mode for burstable types (t3, t4g): standard (slows down when credits run out) or unlimited (bills the extra). Ignored for other types."
  type        = string
  default     = "standard"

  validation {
    condition     = contains(["standard", "unlimited"], var.cpu_credits)
    error_message = "cpu_credits must be standard or unlimited."
  }
}

variable "monitoring_ip" {
  description = "Private IP of the monitoring host, to allow pushing metrics (9090) to it. Null: no monitoring host."
  type        = string
  default     = null
}

variable "parameter_prefix" {
  description = "Parameter Store path this host may read, for example /bmc/dev/app. It can read nothing outside it."
  type        = string

  validation {
    condition     = can(regex("^/[A-Za-z0-9_./-]+[^/]$", var.parameter_prefix))
    error_message = "parameter_prefix must start with / and not end with /, for example /bmc/dev/app."
  }
}

variable "database_users_parameter_path" {
  description = "Parameter Store path of the service database users' passwords, for example /bmc/dev/database/users. Null: no database access."
  type        = string
  default     = null

  validation {
    condition     = var.database_users_parameter_path == null || can(regex("^/[A-Za-z0-9_./-]+[^/]$", var.database_users_parameter_path))
    error_message = "database_users_parameter_path must start with / and not end with /, for example /bmc/dev/database/users."
  }
}
