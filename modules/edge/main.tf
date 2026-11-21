# Edge host for one environment: the only host in the public subnet.
#
#   outbound  NAT for the private subnet (the private route table sends
#             0.0.0.0/0 here), so private hosts reach the internet without a
#             NAT gateway and cannot be reached from it.
#   inbound   when forward_to_ip is set, TCP 80/443 is forwarded (DNAT) to
#             that private address, the application host's Traefik. TLS and
#             routing stay in Traefik; the client's IP is kept, because the
#             private hosts' replies come back through this host.
#
# It runs no application code, holds no secrets and may read no parameters.
# Administration goes through SSM Session Manager; no SSH port is open.

# The image is pinned (ami_id): changing it is a reviewed change that
# replaces the host. The instance type decides the CPU architecture; the
# check on aws_instance.edge stops a plan whose image does not match it.
data "aws_ec2_instance_type" "edge" {
  instance_type = var.instance_type
}

# Only Amazon's images are accepted. include_deprecated: the pin keeps
# resolving after AWS deprecates the image (about three months after release).
data "aws_ami" "edge" {
  owners             = ["amazon"]
  include_deprecated = true

  filter {
    name   = "image-id"
    values = [var.ami_id]
  }
}

locals {
  forwarding = var.forward_to_ip != null
}

# --- Network access ---------------------------------------------------------

# name_prefix and create_before_destroy: a replacement group is created next
# to the old one (a group in use cannot be deleted first).
resource "aws_security_group" "edge" {
  name_prefix = "${var.name}-edge-"
  description = "Edge host: web traffic in, NAT for the private subnet"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name}-edge" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "web" {
  for_each = local.forwarding ? toset(["80", "443"]) : toset([])

  security_group_id = aws_security_group.edge.id
  description       = "Web, port ${each.key}, forwarded to the application host"
  ip_protocol       = "tcp"
  from_port         = tonumber(each.key)
  to_port           = tonumber(each.key)
  cidr_ipv4         = "0.0.0.0/0"
}

# Everything from the private subnet: NAT traffic arrives addressed to
# internet destinations, so it cannot be narrowed by port or address here. The
# private hosts' own security groups limit what they send.
resource "aws_vpc_security_group_ingress_rule" "private" {
  for_each = toset(var.private_cidrs)

  security_group_id = aws_security_group.edge.id
  description       = "Traffic from the private subnet to NAT"
  ip_protocol       = "-1"
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.edge.id
  description       = "NAT and forwarded traffic"
  ip_protocol       = "-1"
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

resource "aws_iam_role" "edge" {
  name_prefix          = "${var.name}-edge-"
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
  role   = aws_iam_role.edge.id
  policy = data.aws_iam_policy_document.session_manager.json
}

resource "aws_iam_instance_profile" "edge" {
  name_prefix = "${var.name}-edge-"
  role        = aws_iam_role.edge.name
}

# --- Host -----------------------------------------------------------------------

resource "aws_instance" "edge" {
  ami           = data.aws_ami.edge.id
  instance_type = var.instance_type
  subnet_id     = var.subnet_id
  # Its public address: assigned by AWS, it changes when the host is stopped
  # and started, and is not billed while stopped (an Elastic IP would be).
  # Use an Elastic IP once a DNS name must point here.
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.edge.id]
  iam_instance_profile        = aws_iam_instance_profile.edge.name
  # Forwards traffic that is not addressed to itself.
  source_dest_check = false

  # IMDSv2 only; hop limit 1 (nothing on this host runs in containers).
  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
  }

  # Burstable types only (t3, t4g): "standard" slows the CPU down when its
  # credits run out instead of billing the extra ("unlimited").
  dynamic "credit_specification" {
    for_each = data.aws_ec2_instance_type.edge.burstable_performance_supported ? [var.cpu_credits] : []
    content {
      cpu_credits = credit_specification.value
    }
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 8
    encrypted   = true
  }

  user_data = templatefile("${path.module}/user-data.sh.tftpl", {
    private_cidrs = var.private_cidrs
    vpc_cidr      = var.vpc_cidr
    forward_to_ip = var.forward_to_ip
  })
  user_data_replace_on_change = true

  lifecycle {
    # A stopped instance has no public IP, so AWS reports this as false while
    # dev is stopped; without this, every plan then would replace the host.
    # The start action (CI) makes sure the edge host has a public IP.
    ignore_changes = [associate_public_ip_address]

    precondition {
      condition     = contains(data.aws_ec2_instance_type.edge.supported_architectures, data.aws_ami.edge.architecture)
      error_message = "The image's architecture does not match the instance type (for example an arm64 image on an x86_64 type)."
    }
  }

  tags = { Name = "${var.name}-edge" }
}

# The private subnet's way out.
resource "aws_route" "private_default" {
  route_table_id         = var.private_route_table_id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.edge.primary_network_interface_id
}
