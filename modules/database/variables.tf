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
  description = "EC2 instance type; x86_64, like the bmc-database AMI (for example t3.micro)."
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

variable "root_volume_size" {
  description = "Root volume in GiB: OS, Docker, the MySQL image, logs. MySQL data is on the data volume."
  type        = number
  default     = 12
}

variable "vpc_id" {
  type = string
}

variable "subnet_id" {
  description = "Private subnet for the host; the data volume is created in its zone."
  type        = string
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

variable "monitoring_ip" {
  description = "Private IP of the monitoring host, to allow pushing metrics (9090) to it. Null: no monitoring host."
  type        = string
  default     = null
}

variable "private_ip" {
  description = "Fixed private address in the subnet, so the application host's firewall can point at it. Null: AWS picks one."
  type        = string
  default     = null
}

variable "databases" {
  description = "One MySQL database and one user of the same name per service, created at every boot. Each user's password is <parameter prefix>/users/<name> in Parameter Store."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for d in var.databases : can(regex("^[a-z][a-z0-9_]{0,31}$", d))])
    error_message = "Database names must be lowercase letters, digits and _, starting with a letter, at most 32 characters."
  }
}
