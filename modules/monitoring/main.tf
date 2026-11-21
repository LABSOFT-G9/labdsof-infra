# Monitoring host for one environment: one plain EC2 instance in the private
# subnet, with no software added yet (Prometheus, Loki and Grafana are added
# case by case). Agents on the other hosts will push to it: metrics to 9090
# (Prometheus remote write), logs to 3100 (Loki). It has no public IP; Grafana
# will be reached through SSM Session Manager port forwarding. It reaches the
# internet through the edge host's NAT.

# Newest Amazon Linux 2023 when the host is created. A newer image does not
# replace a running host (ignore_changes below); replace it on purpose with
# `terraform apply -replace=module.monitoring[0].aws_instance.monitoring`.
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-${var.architecture}"
}

locals {
  push_ports = { metrics = 9090, logs = 3100 }
  # One rule per (client group, port). Keys use the list index, because the
  # group IDs may not be known until apply.
  push_rules = {
    for pair in setproduct(range(length(var.client_security_group_ids)), keys(local.push_ports)) :
    "${pair[0]}-${pair[1]}" => {
      group = var.client_security_group_ids[pair[0]]
      kind  = pair[1]
      port  = local.push_ports[pair[1]]
    }
  }
}

# --- Network access ---------------------------------------------------------

resource "aws_security_group" "monitoring" {
  name        = "${var.name}-monitoring"
  description = "Monitoring host: metrics and logs pushed from the other hosts"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name}-monitoring" }
}

resource "aws_vpc_security_group_ingress_rule" "push" {
  for_each = local.push_rules

  security_group_id            = aws_security_group.monitoring.id
  description                  = "Push ${each.value.kind} (${each.value.port})"
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
  name                 = "${var.name}-monitoring"
  assume_role_policy   = data.aws_iam_policy_document.assume.json
  permissions_boundary = var.permissions_boundary
}

# Session Manager access (also for port forwarding to Grafana) instead of SSH.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "monitoring" {
  name = "${var.name}-monitoring"
  role = aws_iam_role.monitoring.name
}

# --- Host -----------------------------------------------------------------------

resource "aws_instance" "monitoring" {
  ami                         = data.aws_ssm_parameter.al2023.value
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

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size
    encrypted   = true
  }

  lifecycle {
    ignore_changes = [ami]
  }

  tags = { Name = "${var.name}-monitoring" }
}
