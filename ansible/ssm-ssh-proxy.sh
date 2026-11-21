#!/bin/bash
# SSH ProxyCommand: SSH to an EC2 instance through SSM Session Manager, with no
# open port and no permanent key on the host. It pushes your public key to the
# instance with EC2 Instance Connect (valid for 60 seconds, enough to log in),
# then opens a Session Manager tunnel to the instance's SSH port.
#
#   ProxyCommand ssm-ssh-proxy.sh %h %r %p      (%h = instance ID)
#
# Key: BMC_SSH_KEY (default ~/.ssh/bmc_dev; the .pub file next to it is sent).
# Needs AWS credentials and the Session Manager plugin.
set -euo pipefail

instance_id=$1 user=$2 port=$3
key="${BMC_SSH_KEY:-$HOME/.ssh/bmc_dev}"
region="${AWS_REGION:-eu-north-1}"

aws ec2-instance-connect send-ssh-public-key --region "$region" \
  --instance-id "$instance_id" --instance-os-user "$user" \
  --ssh-public-key "file://${key}.pub" >/dev/null
exec aws ssm start-session --region "$region" --target "$instance_id" \
  --document-name AWS-StartSSHSession --parameters "portNumber=${port}"
