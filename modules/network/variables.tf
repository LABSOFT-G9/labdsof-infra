variable "name" {
  description = "Prefix for resource names, for example bmc-dev."
  type        = string
}

variable "region" {
  description = "AWS region, used for the S3 endpoint's service name."
  type        = string
}

variable "cidr_block" {
  description = "VPC CIDR. The public subnet is the first /24 inside it, the private subnet the second."
  type        = string
}

variable "availability_zone" {
  description = "Availability zone for both subnets. Null picks the first available one."
  type        = string
  default     = null
}
