# dev: cheap and disposable (created to test, then destroyed). The database
# takes the newest bmc-database build; the other hosts use pinned images.
environment        = "dev"
region             = "eu-north-1"
availability_zone  = "eu-north-1a"
vpc_cidr           = "10.10.0.0/16"
edge_instance_type = "t3.nano"
# al2023-ami-2023.12.20261120.0-kernel-6.18-x86_64 (Amazon, built 2026-11-20)
edge_ami_id       = "ami-083dedce92603a2ad"
app_enabled       = true
app_instance_type = "t3.large"
# al2023-ami-2023.12.20261120.0-kernel-6.18-x86_64 (Amazon, built 2026-11-20)
app_ami_id               = "ami-083dedce92603a2ad"
monitoring_enabled       = true
monitoring_instance_type = "t3.small"
# al2023-ami-2023.12.20261120.0-kernel-6.18-x86_64 (Amazon, built 2026-11-20)
monitoring_ami_id      = "ami-083dedce92603a2ad"
database_enabled       = false
database_ami_version   = "*"
database_instance_type = "t3.micro"
database_volume_size   = 10
deletion_protection    = false
backup_retention_days  = 7
backup_lock_days       = 0
force_destroy_buckets  = true
