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

variable "vpc_cidr" {
  description = "VPC CIDR: traffic inside it is never NATed or forwarded."
  type        = string
}

variable "subnet_id" {
  description = "Public subnet for the host."
  type        = string
}

variable "private_cidrs" {
  description = "CIDRs of the private subnets that use this host as NAT."
  type        = list(string)
}

variable "private_route_table_id" {
  description = "Route table of the private subnets; gets 0.0.0.0/0 through this host."
  type        = string
}

variable "forward_to_ip" {
  description = "Private IP of the application host to forward TCP 80/443 to. Null: no forwarding and ports 80/443 closed."
  type        = string
  default     = null
}

variable "permissions_boundary" {
  description = "ARN of the IAM permissions boundary every workload role must carry (bootstrap policy bmc-workload-boundary)."
  type        = string
}
