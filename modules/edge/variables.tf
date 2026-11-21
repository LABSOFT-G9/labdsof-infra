variable "name" {
  description = "Prefix for resource names, for example bmc-dev."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type; arm64 (Graviton), for example t4g.nano."
  type        = string
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
