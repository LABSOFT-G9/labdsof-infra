#!/bin/bash
# Installs Docker, the AWS CLI, the pinned container images and the BMC
# database scripts and units. Runs as root during the Packer build.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get -y install --no-install-recommends docker.io docker-compose-v2 gzip jq nvme-cli
systemctl enable docker
systemctl start docker

# AWS CLI v2 (backups to S3, secrets from SSM). The SSM agent ships with
# Ubuntu's AWS images.
snap install aws-cli --classic

install -d -m 0755 /opt/bmc /opt/bmc/bin /etc/bmc
install -m 0644 /tmp/bmc/compose.yaml /opt/bmc/compose.yaml
install -m 0755 /tmp/bmc/bootstrap.sh /opt/bmc/bin/bootstrap.sh
install -m 0755 /tmp/bmc/backup.sh /opt/bmc/bin/backup.sh
install -m 0644 /tmp/bmc/bmc-database.service /etc/systemd/system/bmc-database.service
install -m 0644 /tmp/bmc/bmc-backup.service /etc/systemd/system/bmc-backup.service
install -m 0644 /tmp/bmc/bmc-backup.timer /etc/systemd/system/bmc-backup.timer

# Pull the pinned images now, so a host never needs Docker Hub at runtime.
docker compose -f /opt/bmc/compose.yaml pull

rm -rf /tmp/bmc
apt-get clean
rm -rf /var/lib/apt/lists/*
