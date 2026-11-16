# Database host image: Ubuntu 24.04 LTS + Docker, with the MySQL and
# mysqld_exporter images (pinned by digest in files/compose.yaml) already
# pulled, the bootstrap and backup scripts, and their systemd units.
# Configuration and secrets are not baked in: Terraform user data and SSM
# Parameter Store provide them at boot.
#
#   packer init ami/database
#   packer build -var version=1.0.0 ami/database
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
  default = "eu-west-1"
}

variable "instance_type" {
  description = "Temporary build instance."
  type        = string
  default     = "t3.small"
}

source "amazon-ebs" "database" {
  region        = var.region
  instance_type = var.instance_type
  ami_name      = "bmc-database-${var.version}"
  ssh_username  = "ubuntu"

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

  provisioner "file" {
    source      = "${path.root}/files/"
    destination = "/tmp/bmc"
  }

  provisioner "shell" {
    execute_command = "sudo -E bash '{{ .Path }}'"
    scripts = [
      "${path.root}/scripts/harden.sh",
      "${path.root}/scripts/install.sh",
    ]
  }
}
