# prod: private subnet, protected, longer and locked backups. The AMI version
# is pinned, so a new image reaches prod only by changing this line in a PR.
environment                = "prod"
region                     = "eu-west-1"
vpc_cidr                   = "10.20.0.0/16"
database_ami_version       = "1.0.0"
database_instance_type     = "t3.small"
database_volume_size       = 20
database_in_private_subnet = true
deletion_protection        = true
backup_retention_days      = 30
backup_lock_days           = 14
force_destroy_buckets      = false
