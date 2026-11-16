# Database host for one environment: one EC2 instance started from the
# bmc-database AMI (ami/database), with MySQL data on a separate encrypted EBS
# volume so the instance can be replaced by a newer AMI without losing data.
#
# The AMI holds the software; this module passes the configuration through
# user data. Secrets are not here: the host reads them from SSM Parameter
# Store at boot (docs/runbooks/database.md).

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

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

resource "aws_security_group" "database" {
  name        = "${var.name}-database"
  description = "MySQL from the application host, exporter from monitoring"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name}-database" }
}

resource "aws_vpc_security_group_ingress_rule" "mysql" {
  for_each = toset(var.client_security_group_ids)

  security_group_id            = aws_security_group.database.id
  description                  = "MySQL"
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  referenced_security_group_id = each.value
}

resource "aws_vpc_security_group_ingress_rule" "exporter" {
  for_each = toset(var.monitoring_security_group_ids)

  security_group_id            = aws_security_group.database.id
  description                  = "mysqld_exporter metrics"
  ip_protocol                  = "tcp"
  from_port                    = 9104
  to_port                      = 9104
  referenced_security_group_id = each.value
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
  name                 = "${var.name}-database"
  assume_role_policy   = data.aws_iam_policy_document.assume.json
  permissions_boundary = var.permissions_boundary
}

# Session Manager access instead of SSH.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.database.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
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
  name   = "${var.name}-database"
  role   = aws_iam_role.database.id
  policy = data.aws_iam_policy_document.database.json
}

resource "aws_iam_instance_profile" "database" {
  name = "${var.name}-database"
  role = aws_iam_role.database.name
}

# --- Host and data volume ---------------------------------------------------

resource "aws_instance" "database" {
  ami                         = data.aws_ami.database.id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  associate_public_ip_address = var.public_ip
  vpc_security_group_ids      = [aws_security_group.database.id]
  iam_instance_profile        = aws_iam_instance_profile.database.name
  disable_api_termination     = var.deletion_protection

  # IMDSv2 only.
  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  # OS and Docker images only; MySQL data is on the separate data volume.
  root_block_device {
    volume_type = "gp3"
    volume_size = 8
    encrypted   = true
  }

  user_data = templatefile("${path.module}/user-data.sh.tftpl", {
    environment      = var.environment
    region           = data.aws_region.current.region
    backups_bucket   = var.backups_bucket
    parameter_prefix = local.parameter_prefix
    data_volume_id   = aws_ebs_volume.data.id
    backup_schedule  = var.backup_schedule
  })
  user_data_replace_on_change = true

  tags = {
    Name       = "${var.name}-database"
    AmiVersion = var.ami_version
  }
}

resource "aws_ebs_volume" "data" {
  availability_zone = var.availability_zone
  size              = var.data_volume_size
  type              = "gp3"
  encrypted         = true

  tags = { Name = "${var.name}-database-data" }
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.database.id
}
