# Monitoring host for one environment: one EC2 instance in the private subnet
# for Prometheus, Loki and Grafana (installed by Ansible,
# ansible/roles/monitoring). The agents on every host push metrics to it on
# 9090 (Prometheus remote write) and logs on 3100 (Loki). It has no public IP; Grafana
# will be reached through SSM Session Manager port forwarding. It reaches the
# internet through the edge host's NAT.

# The image is pinned (ami_id): changing it is a reviewed change that
# replaces the host. The instance type decides the CPU architecture; the
# check on aws_instance.monitoring stops a plan whose image does not match it.
data "aws_ec2_instance_type" "monitoring" {
  instance_type = var.instance_type
}

# Only Amazon's images are accepted. include_deprecated: the pin keeps
# resolving after AWS deprecates the image (about three months after release).
data "aws_ami" "monitoring" {
  owners             = ["amazon"]
  include_deprecated = true

  filter {
    name   = "image-id"
    values = [var.ami_id]
  }
}

locals {
  push_ports = { metrics = 9090, logs = 3100 }
  # One rule per (sending host, port), keyed by the host's name (for example
  # "app-metrics"), so switching one host off does not touch the others' rules.
  push_rules = {
    for pair in setproduct(keys(var.client_security_group_ids), keys(local.push_ports)) :
    "${pair[0]}-${pair[1]}" => {
      host  = pair[0]
      group = var.client_security_group_ids[pair[0]]
      kind  = pair[1]
      port  = local.push_ports[pair[1]]
    }
  }
}

# --- Network access ---------------------------------------------------------

# name_prefix and create_before_destroy: a replacement group is created next
# to the old one (a group in use cannot be deleted first).
resource "aws_security_group" "monitoring" {
  name_prefix = "${var.name}-monitoring-"
  description = "Monitoring host: metrics and logs pushed from the other hosts"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name}-monitoring" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "push" {
  for_each = local.push_rules

  security_group_id            = aws_security_group.monitoring.id
  description                  = "Push ${each.value.kind} (${each.value.port}) from the ${each.value.host} host"
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
  referenced_security_group_id = each.value.group
}

# Outbound: the internet over HTTP/HTTPS through the edge host's NAT
# (packages, SSM).
resource "aws_vpc_security_group_egress_rule" "web" {
  for_each = toset(["80", "443"])

  security_group_id = aws_security_group.monitoring.id
  description       = "Internet, port ${each.key}"
  ip_protocol       = "tcp"
  from_port         = tonumber(each.key)
  to_port           = tonumber(each.key)
  cidr_ipv4         = "0.0.0.0/0"
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

resource "aws_iam_role" "monitoring" {
  name_prefix          = "${var.name}-monitoring-"
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
  role   = aws_iam_role.monitoring.id
  policy = data.aws_iam_policy_document.session_manager.json
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Its own Parameter Store path only (for example the Grafana admin password).
data "aws_iam_policy_document" "monitoring" {
  statement {
    sid       = "ReadOwnParameters"
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = ["arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter${var.parameter_prefix}/*"]
  }
}

resource "aws_iam_role_policy" "monitoring" {
  name   = "monitoring"
  role   = aws_iam_role.monitoring.id
  policy = data.aws_iam_policy_document.monitoring.json
}

resource "aws_iam_instance_profile" "monitoring" {
  name_prefix = "${var.name}-monitoring-"
  role        = aws_iam_role.monitoring.name
}

# --- Host -----------------------------------------------------------------------

resource "aws_instance" "monitoring" {
  ami                         = data.aws_ami.monitoring.id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  private_ip                  = var.private_ip
  associate_public_ip_address = false
  vpc_security_group_ids      = [aws_security_group.monitoring.id]
  iam_instance_profile        = aws_iam_instance_profile.monitoring.name
  disable_api_termination     = var.deletion_protection

  # IMDSv2 only; hop limit 1 keeps containers from reading the host's
  # credentials through the metadata service.
  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
  }

  # Burstable types only (t3, t4g): "standard" slows the CPU down when its
  # credits run out instead of billing the extra ("unlimited").
  dynamic "credit_specification" {
    for_each = data.aws_ec2_instance_type.monitoring.burstable_performance_supported ? [var.cpu_credits] : []
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
      condition     = contains(data.aws_ec2_instance_type.monitoring.supported_architectures, data.aws_ami.monitoring.architecture)
      error_message = "The image's architecture does not match the instance type (for example an arm64 image on an x86_64 type)."
    }
  }

  # Role: Ansible finds the host by it (ansible/inventory).
  tags = { Name = "${var.name}-monitoring", Role = "monitoring" }
}
