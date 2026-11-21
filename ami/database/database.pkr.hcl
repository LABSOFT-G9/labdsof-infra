# Database host image: Ubuntu 24.04 LTS configured by Ansible
# (ansible/database-image.yml: hardening, Docker, the MySQL and
# mysqld_exporter images pinned by digest and already pulled, the bootstrap
# and backup scripts, their systemd units). Configuration and secrets are not
# baked in: Terraform user data and SSM Parameter Store provide them at boot.
#
#   packer init ami/database
#   packer build -var version=1.0.0 ami/database
#
# Where it builds: a temporary instance in dev's private subnet (dev must be
# applied), reached through SSM Session Manager. No public IP, no open port;
# it reaches the internet through the edge host's NAT. Needs, where Packer
# runs: AWS credentials, Ansible and the Session Manager plugin for the AWS CLI
# (README "Database host").
#
# The result is named bmc-database-<version>; modules/database selects it.
# Patching is done by building a new version, not by updating running hosts.

packer {
  required_version = ">= 1.11.0"

  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = "~> 1.8"
    }
    ansible = {
      source  = "github.com/hashicorp/ansible"
      version = "~> 1.1"
    }
  }
}

variable "version" {
  description = "Image version, MAJOR.MINOR.PATCH. The AMI is named bmc-database-<version>."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.version))
    error_message = "The version must look like 1.0.0."
  }
}

variable "region" {
  type    = string
  default = "eu-north-1"
}

variable "instance_type" {
  description = "Temporary build instance (x86_64, like the image)."
  type        = string
  default     = "t3.small"
}

variable "build_subnet_name" {
  description = "Name tag of the private subnet the temporary instance runs in."
  type        = string
  default     = "bmc-dev-private"
}

source "amazon-ebs" "database" {
  region        = var.region
  instance_type = var.instance_type
  ami_name      = "bmc-database-${var.version}"
  ssh_username  = "ubuntu"

  # Inside dev's private subnet, reached through Session Manager: Packer's SSH
  # runs through an SSM tunnel, so the instance needs no public IP and no
  # inbound rule (the temporary security group allows nothing real).
  subnet_filter {
    filters = {
      "tag:Name" = var.build_subnet_name
    }
  }
  associate_public_ip_address           = false
  ssh_interface                         = "session_manager"
  ssh_timeout                           = "15m"
  temporary_security_group_source_cidrs = ["127.0.0.1/32"]

  # The temporary instance may only register with SSM and open sessions.
  temporary_iam_instance_profile_policy_document {
    Version = "2012-10-17"
    Statement {
      Effect   = "Allow"
      Action   = ["ssm:UpdateInstanceInformation"]
      Resource = ["*"]
    }
    Statement {
      Effect = "Allow"
      Action = [
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel",
      ]
      Resource = ["*"]
    }
  }

  # Latest Ubuntu 24.04 LTS (amd64) from Canonical's account.
  source_ami_filter {
    filters = {
      name                = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    owners      = ["099720109477"]
    most_recent = true
  }

  encrypt_boot = true
  imds_support = "v2.0"

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  tags = {
    Name        = "bmc-database-${var.version}"
    Version     = var.version
    Project     = "bmc"
    Role        = "database"
    BaseAMI     = "{{ .SourceAMI }}"
    BaseAMIName = "{{ .SourceAMIName }}"
  }
}

build {
  sources = ["source.amazon-ebs.database"]

  # Ansible runs where Packer runs and reaches the instance through Packer's
  # SSH proxy (use_proxy), which goes over the Session Manager tunnel.
  provisioner "ansible" {
    playbook_file = "${path.root}/../../ansible/database-image.yml"
    user          = "ubuntu"
    use_proxy     = true
    ansible_env_vars = [
      "ANSIBLE_CONFIG=${path.root}/../../ansible/ansible.cfg",
    ]
    # OpenSSH 9+ copies files over SFTP by default; Packer's proxy needs the
    # classic scp protocol.
    extra_arguments = ["--scp-extra-args", "'-O'"]
  }
}
