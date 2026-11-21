variable "name" {
  description = "Prefix for resource names, for example bmc-dev."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type. Must match architecture (t4g/m7g are arm64, t3/m7i are x86_64)."
  type        = string
}

variable "architecture" {
  description = "CPU architecture of instance_type: arm64 or x86_64."
  type        = string
  default     = "arm64"

  validation {
    condition     = contains(["arm64", "x86_64"], var.architecture)
    error_message = "architecture must be arm64 or x86_64."
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
  description = "Fixed private address in the subnet, so the other hosts know where to push."
  type        = string
}

variable "client_security_group_ids" {
  description = "Security groups of the hosts allowed to push metrics (9090) and logs (3100)."
  type        = list(string)
}

variable "root_volume_size" {
  description = "Root volume in GiB (metrics and logs are kept on it)."
  type        = number
  default     = 20
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
