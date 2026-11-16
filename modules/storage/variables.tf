variable "name" {
  description = "Prefix for bucket names, for example bmc-dev."
  type        = string
}

variable "backup_retention_days" {
  description = "Days a backup is kept before it expires."
  type        = number
}

variable "backup_lock_days" {
  description = "Object Lock (governance mode) on new backups, in days. 0 disables Object Lock. Changing it from 0 to more requires a new bucket."
  type        = number
  default     = 0

  validation {
    condition     = var.backup_lock_days >= 0
    error_message = "backup_lock_days must be 0 or more."
  }
}

variable "noncurrent_version_days" {
  description = "Days a replaced or deleted object version is kept."
  type        = number
  default     = 7
}

variable "force_destroy" {
  description = "Allow terraform destroy to delete non-empty buckets. Only for disposable environments."
  type        = bool
  default     = false
}
