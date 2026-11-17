# prod: a short-lived showcase of promotion. It differs from dev where the
# difference shows something (pinned AMI, private subnet, bigger host, longer
# backup retention) but, like dev, it can be destroyed in one step: no
# termination protection, no Object Lock, buckets deletable when not empty.
# For a long-lived prod, set deletion_protection = true, force_destroy_buckets
# = false and backup_lock_days > 0 (the lock needs a new backups bucket).
environment                = "prod"
region                     = "eu-west-1"
vpc_cidr                   = "10.20.0.0/16"
database_enabled           = false
database_ami_version       = "1.0.0"
database_instance_type     = "t3.small"
database_volume_size       = 10
database_in_private_subnet = true
deletion_protection        = false
backup_retention_days      = 30
backup_lock_days           = 0
force_destroy_buckets      = true
