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
# It runs no application code and holds no secrets. Administration goes
# through SSM Session Manager; no SSH port is open.

# Newest Amazon Linux 2023 for arm64 when the host is created. A newer image
# does not replace a running host (ignore_changes below); replace it on
# purpose with `terraform apply -replace=module.edge.aws_instance.edge`.
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

locals {
  forwarding = var.forward_to_ip != null
}

# --- Network access ---------------------------------------------------------

resource "aws_security_group" "edge" {
  name        = "${var.name}-edge"
  description = "Edge host: web traffic in, NAT for the private subnet"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name}-edge" }
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
  name                 = "${var.name}-edge"
  assume_role_policy   = data.aws_iam_policy_document.assume.json
  permissions_boundary = var.permissions_boundary
}

# Session Manager access instead of SSH; nothing else.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.edge.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "edge" {
  name = "${var.name}-edge"
  role = aws_iam_role.edge.name
}

# --- Host -----------------------------------------------------------------------

resource "aws_instance" "edge" {
  ami           = data.aws_ssm_parameter.al2023.value
  instance_type = var.instance_type
  subnet_id     = var.subnet_id
  # Needed during the first boot (packages) until the Elastic IP is attached.
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.edge.id]
  iam_instance_profile        = aws_iam_instance_profile.edge.name
  # Forwards traffic that is not addressed to itself.
  source_dest_check = false

  # IMDSv2 only.
  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
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
    ignore_changes = [ami]
  }

  tags = { Name = "${var.name}-edge" }
}

# Fixed public address: survives stop/start, so DNS can point at it.
resource "aws_eip" "edge" {
  domain   = "vpc"
  instance = aws_instance.edge.id

  tags = { Name = "${var.name}-edge" }
}

# The private subnet's way out.
resource "aws_route" "private_default" {
  route_table_id         = var.private_route_table_id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.edge.primary_network_interface_id
}
