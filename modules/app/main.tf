# Application host for one environment: one plain EC2 instance in the
# private subnet, with no software added yet (runtime, deployment and
# application permissions are decided case by case). It has no public IP:
# web traffic reaches it only through the edge host's forwarding
# (modules/edge), and it reaches the internet through the edge host's NAT.

# Newest Amazon Linux 2023 when the host is created. A newer image does not
# replace a running host (ignore_changes below); replace it on purpose with
# `terraform apply -replace=module.app[0].aws_instance.app`.
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-${var.architecture}"
}

# --- Network access ---------------------------------------------------------

resource "aws_security_group" "app" {
  name        = "${var.name}-app"
  description = "Application host"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name}-app" }
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
# (packages, SSM) and MySQL inside the VPC.
resource "aws_vpc_security_group_egress_rule" "web" {
  for_each = toset(["80", "443"])

  security_group_id = aws_security_group.app.id
  description       = "Internet, port ${each.key}"
  ip_protocol       = "tcp"
  from_port         = tonumber(each.key)
  to_port           = tonumber(each.key)
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "mysql" {
  security_group_id = aws_security_group.app.id
  description       = "MySQL to the database host"
  ip_protocol       = "tcp"
  from_port         = 3306
  to_port           = 3306
  cidr_ipv4         = var.vpc_cidr
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
  name                 = "${var.name}-app"
  assume_role_policy   = data.aws_iam_policy_document.assume.json
  permissions_boundary = var.permissions_boundary
}

# Session Manager access instead of SSH. Application permissions (buckets,
# parameters) are added when the deployment is defined.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "app" {
  name = "${var.name}-app"
  role = aws_iam_role.app.name
}

# --- Host -----------------------------------------------------------------------

resource "aws_instance" "app" {
  ami                         = data.aws_ssm_parameter.al2023.value
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  private_ip                  = var.private_ip
  associate_public_ip_address = false
  vpc_security_group_ids      = [aws_security_group.app.id]
  iam_instance_profile        = aws_iam_instance_profile.app.name
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

  tags = { Name = "${var.name}-app" }
}
