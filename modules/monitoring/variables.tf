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

variable "cpu_credits" {
  description = "Credit mode for burstable types (t3, t4g): standard (slows down when credits run out) or unlimited (bills the extra). Ignored for other types."
  type        = string
  default     = "standard"

  validation {
    condition     = contains(["standard", "unlimited"], var.cpu_credits)
    error_message = "cpu_credits must be standard or unlimited."
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
  description = "Hosts allowed to push metrics (9090) and logs (3100): host name => its security group, for example { edge = sg-..., app = sg-... }."
  type        = map(string)
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

variable "parameter_prefix" {
  description = "Parameter Store path this host may read, for example /bmc/dev/monitoring. It can read nothing outside it."
  type        = string

  validation {
    condition     = can(regex("^/[A-Za-z0-9_./-]+[^/]$", var.parameter_prefix))
    error_message = "parameter_prefix must start with / and not end with /, for example /bmc/dev/monitoring."
  }
}
