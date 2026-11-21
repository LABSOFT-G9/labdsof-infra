# Application host for one environment: one plain EC2 instance in the
# private subnet, with no software added yet (runtime, deployment and
# application permissions are decided case by case). It has no public IP:
# web traffic reaches it only through the edge host's forwarding
# (modules/edge), and it reaches the internet through the edge host's NAT.

# The image is pinned (ami_id): changing it is a reviewed change that
# replaces the host. The instance type decides the CPU architecture; the
# check on aws_instance.app stops a plan whose image does not match it.
data "aws_ec2_instance_type" "app" {
  instance_type = var.instance_type
}

# Only Amazon's images are accepted. include_deprecated: the pin keeps
# resolving after AWS deprecates the image (about three months after release).
data "aws_ami" "app" {
  owners             = ["amazon"]
  include_deprecated = true

  filter {
    name   = "image-id"
    values = [var.ami_id]
  }
}

# --- Network access ---------------------------------------------------------

# name_prefix and create_before_destroy: a replacement group is created next
# to the old one (a group in use cannot be deleted first).
resource "aws_security_group" "app" {
  name_prefix = "${var.name}-app-"
  description = "Application host"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name}-app" }

  lifecycle {
    create_before_destroy = true
  }
}

# Web traffic arrives only through the edge host's forwarding, which keeps the
# client's address: hence 80/443 from anywhere, although nothing outside the
# VPC can route to this host directly.
resource "aws_vpc_security_group_ingress_rule" "web" {
  for_each = toset(["80", "443"])

  security_group_id = aws_security_group.app.id
  description       = "Web, port ${each.key}, forwarded by the edge host"
  ip_protocol       = "tcp"
  from_port         = tonumber(each.key)
  to_port           = tonumber(each.key)
  cidr_ipv4         = "0.0.0.0/0"
}

# Outbound: the internet over HTTP/HTTPS through the edge host's NAT
# (packages, images, SSM; S3 goes through the gateway endpoint).
resource "aws_vpc_security_group_egress_rule" "web" {
  for_each = toset(["80", "443"])

  security_group_id = aws_security_group.app.id
  description       = "Internet, port ${each.key}"
  ip_protocol       = "tcp"
  from_port         = tonumber(each.key)
  to_port           = tonumber(each.key)
  cidr_ipv4         = "0.0.0.0/0"
}

# MySQL to the database host only, when there is one.
resource "aws_vpc_security_group_egress_rule" "mysql" {
  count = var.database_ip == null ? 0 : 1

  security_group_id = aws_security_group.app.id
  description       = "MySQL to the database host"
  ip_protocol       = "tcp"
  from_port         = 3306
  to_port           = 3306
  cidr_ipv4         = "${var.database_ip}/32"
}

# Push metrics (9090) and logs (3100) to the monitoring host, when there is one.
resource "aws_vpc_security_group_egress_rule" "monitoring" {
  for_each = var.monitoring_ip == null ? {} : { metrics = 9090, logs = 3100 }

  security_group_id = aws_security_group.app.id
  description       = "Push ${each.key} to the monitoring host"
  ip_protocol       = "tcp"
  from_port         = each.value
  to_port           = each.value
  cidr_ipv4         = "${var.monitoring_ip}/32"
}

# --- Permissions --------------------------------------------------------------

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "app" {
  name_prefix          = "${var.name}-app-"
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
  role   = aws_iam_role.app.id
  policy = data.aws_iam_policy_document.session_manager.json
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# What the application itself may use:
#   - its own Parameter Store path (parameter_prefix), and the database
#     users' passwords (database_users_parameter_path) when set, nothing else
#     (not the database's root, backup or exporter passwords);
#   - its attachments bucket (for example photos): list, read and write.
#     Deleting is not allowed (the workload boundary does not allow it).
data "aws_iam_policy_document" "app" {
  statement {
    sid       = "ReadOwnParameters"
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = ["arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter${var.parameter_prefix}/*"]
  }
  dynamic "statement" {
    for_each = var.database_users_parameter_path == null ? [] : [var.database_users_parameter_path]
    content {
      sid       = "ReadDatabaseUserPasswords"
      actions   = ["ssm:GetParameter", "ssm:GetParameters"]
      resources = ["arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter${statement.value}/*"]
    }
  }
  statement {
    sid       = "ListAttachments"
    actions   = ["s3:ListBucket"]
    resources = [var.attachments_bucket_arn]
  }
  statement {
    sid       = "ReadWriteAttachments"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${var.attachments_bucket_arn}/*"]
  }
}

resource "aws_iam_role_policy" "app" {
  name   = "app"
  role   = aws_iam_role.app.id
  policy = data.aws_iam_policy_document.app.json
}

resource "aws_iam_instance_profile" "app" {
  name_prefix = "${var.name}-app-"
  role        = aws_iam_role.app.name
}

# --- Host -----------------------------------------------------------------------

resource "aws_instance" "app" {
  ami                         = data.aws_ami.app.id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  private_ip                  = var.private_ip
  associate_public_ip_address = false
  vpc_security_group_ids      = [aws_security_group.app.id]
  iam_instance_profile        = aws_iam_instance_profile.app.name
  disable_api_termination     = var.deletion_protection

  # IMDSv2 only. Hop limit 2 lets containers use the host's role (S3
  # attachments); everything the role allows is then open to every container.
  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
  }

  # Burstable types only (t3, t4g): "standard" slows the CPU down when its
  # credits run out instead of billing the extra ("unlimited").
  dynamic "credit_specification" {
    for_each = data.aws_ec2_instance_type.app.burstable_performance_supported ? [var.cpu_credits] : []
    content {
      cpu_credits = credit_specification.value
    }
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size
    encrypted   = true
  }

  lifecycle {
    precondition {
      condition     = contains(data.aws_ec2_instance_type.app.supported_architectures, data.aws_ami.app.architecture)
      error_message = "The image's architecture does not match the instance type (for example an arm64 image on an x86_64 type)."
    }
  }

  tags = { Name = "${var.name}-app" }
}
