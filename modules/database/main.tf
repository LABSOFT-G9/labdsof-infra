# Database host for one environment: one EC2 instance started from the
# bmc-database AMI (ami/database), with MySQL data on a separate encrypted EBS
# volume so the instance can be replaced by a newer AMI without losing data.
#
# The AMI holds the software; this module passes the configuration through
# user data. Secrets are not here: the host reads them from SSM Parameter
# Store at boot (docs/runbooks/database.md).

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# The data volume must be in the subnet's zone; read it from the subnet.
data "aws_subnet" "database" {
  id = var.subnet_id
}

# The instance type decides the CPU architecture; the check on
# aws_instance.database stops a plan whose image does not match it.
data "aws_ec2_instance_type" "database" {
  instance_type = var.instance_type
}

# Image name is bmc-database-<version>. "*" picks the newest build.
data "aws_ami" "database" {
  most_recent = true
  owners      = ["self"]

  filter {
    name   = "name"
    values = ["bmc-database-${var.ami_version}"]
  }
}

locals {
  parameter_prefix = "/bmc/${var.environment}/database"
  parameter_arn    = "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter${local.parameter_prefix}"
}

# --- Network access ---------------------------------------------------------

# name_prefix and create_before_destroy: a replacement group is created next
# to the old one (a group in use cannot be deleted first).
resource "aws_security_group" "database" {
  name_prefix = "${var.name}-database-"
  description = "MySQL from the application host"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name}-database" }

  lifecycle {
    create_before_destroy = true
  }
}

# count, not for_each: the group IDs may not be known until apply.
resource "aws_vpc_security_group_ingress_rule" "mysql" {
  count = length(var.client_security_group_ids)

  security_group_id            = aws_security_group.database.id
  description                  = "MySQL"
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  referenced_security_group_id = var.client_security_group_ids[count.index]
}

# Outbound HTTPS only: SSM, S3 and package mirrors. No SSH is opened; admins
# connect through SSM Session Manager.
resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.database.id
  description       = "HTTPS to AWS APIs"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

# Push metrics (9090) and logs (3100) to the monitoring host, when there is one.
resource "aws_vpc_security_group_egress_rule" "monitoring" {
  for_each = var.monitoring_ip == null ? {} : { metrics = 9090, logs = 3100 }

  security_group_id = aws_security_group.database.id
  description       = "Push ${each.key} to the monitoring host"
  ip_protocol       = "tcp"
  from_port         = each.value
  to_port           = each.value
  cidr_ipv4         = "${var.monitoring_ip}/32"
}

# --- Permissions (least privilege) -----------------------------------------

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "database" {
  name_prefix          = "${var.name}-database-"
  assume_role_policy   = data.aws_iam_policy_document.assume.json
  permissions_boundary = var.permissions_boundary
}

# Session Manager (and Run Command) only, instead of SSH. Not AWS's
# AmazonSSMManagedInstanceCore: that policy also allows reading every
# Parameter Store parameter (ssm:GetParameter on *), including other hosts'
# secrets.
data "aws_iam_policy_document" "session_manager" {
  statement {
    sid       = "RegisterWithSsm"
    actions   = ["ssm:UpdateInstanceInformation"]
    resources = ["*"]
  }
  statement {
    sid = "SessionChannels"
    actions = [
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"]
  }
  statement {
    sid = "RunCommandMessages"
    actions = [
      "ec2messages:AcknowledgeMessage",
      "ec2messages:DeleteMessage",
      "ec2messages:FailMessage",
      "ec2messages:GetEndpoint",
      "ec2messages:GetMessages",
      "ec2messages:SendReply",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "session_manager" {
  name   = "session-manager"
  role   = aws_iam_role.database.id
  policy = data.aws_iam_policy_document.session_manager.json
}

data "aws_iam_policy_document" "database" {
  # Write new backups only: it cannot read, list or delete them.
  statement {
    sid       = "WriteBackups"
    actions   = ["s3:PutObject"]
    resources = ["${var.backups_bucket_arn}/mysql/*"]
  }

  # Read only this environment's database parameters.
  statement {
    sid       = "ReadDatabaseParameters"
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = ["${local.parameter_arn}/*"]
  }
}

resource "aws_iam_role_policy" "database" {
  name   = "database"
  role   = aws_iam_role.database.id
  policy = data.aws_iam_policy_document.database.json
}

resource "aws_iam_instance_profile" "database" {
  name_prefix = "${var.name}-database-"
  role        = aws_iam_role.database.name
}

# --- Host and data volume ---------------------------------------------------

resource "aws_instance" "database" {
  ami                         = data.aws_ami.database.id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  private_ip                  = var.private_ip
  associate_public_ip_address = false
  vpc_security_group_ids      = [aws_security_group.database.id]
  iam_instance_profile        = aws_iam_instance_profile.database.name
  disable_api_termination     = var.deletion_protection

  # IMDSv2 only. Hop limit 1: only the host's own scripts get the role's
  # credentials, not the MySQL container (some images default
  # to 2).
  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
  }

  # Burstable types only (t3, t4g): "standard" slows the CPU down when its
  # credits run out instead of billing the extra ("unlimited").
  dynamic "credit_specification" {
    for_each = data.aws_ec2_instance_type.database.burstable_performance_supported ? [var.cpu_credits] : []
    content {
      cpu_credits = credit_specification.value
    }
  }

  # OS, Docker and images; MySQL data is on the separate data volume.
  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size
    encrypted   = true
  }

  user_data = templatefile("${path.module}/user-data.sh.tftpl", {
    environment      = var.environment
    region           = data.aws_region.current.region
    backups_bucket   = var.backups_bucket
    parameter_prefix = local.parameter_prefix
    data_volume_id   = aws_ebs_volume.data.id
    backup_schedule  = var.backup_schedule
    databases        = var.databases
  })
  user_data_replace_on_change = true

  lifecycle {
    precondition {
      condition     = contains(data.aws_ec2_instance_type.database.supported_architectures, data.aws_ami.database.architecture)
      error_message = "The image's architecture does not match the instance type (the bmc-database AMI is x86_64)."
    }
  }

  # Role: Ansible finds the host by it (ansible/inventory).
  tags = {
    Name       = "${var.name}-database"
    Role       = "database"
    AmiVersion = var.ami_version
  }
}

resource "aws_ebs_volume" "data" {
  availability_zone = data.aws_subnet.database.availability_zone
  size              = var.data_volume_size
  type              = "gp3"
  encrypted         = true

  tags = { Name = "${var.name}-database-data" }
}

# When the instance is replaced (new AMI), stop it before detaching the volume,
# so MySQL shuts down cleanly instead of losing the disk while writing.
resource "aws_volume_attachment" "data" {
  device_name                    = "/dev/sdf"
  stop_instance_before_detaching = true
  volume_id                      = aws_ebs_volume.data.id
  instance_id                    = aws_instance.database.id
}
