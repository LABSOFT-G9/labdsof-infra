# dev: cheap and disposable (created to test, then destroyed). Takes the
# newest AMI build.
environment              = "dev"
region                   = "eu-north-1"
vpc_cidr                 = "10.10.0.0/16"
edge_instance_type       = "t4g.nano"
app_enabled              = true
app_instance_type        = "t4g.large"
app_architecture         = "arm64"
monitoring_enabled       = true
monitoring_instance_type = "t4g.small"
monitoring_architecture  = "arm64"
database_enabled         = false
database_ami_version     = "*"
database_instance_type   = "t3.micro"
database_volume_size     = 10
deletion_protection      = false
backup_retention_days    = 7
backup_lock_days         = 0
force_destroy_buckets    = true
