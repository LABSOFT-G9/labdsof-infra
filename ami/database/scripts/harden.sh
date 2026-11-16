#!/bin/bash
# Base OS hardening for the database image.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# All updates available at build time. Running hosts are not patched in
# place: build a new image version instead.
apt-get update
apt-get -y -o Dpkg::Options::="--force-confold" upgrade
apt-get -y purge unattended-upgrades || true

# No passwords and no root login over SSH. The security group opens no SSH
# port anyway; admins use SSM Session Manager.
install -d -m 0755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/10-bmc.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
EOF

# Kernel network settings for a host that does not route traffic.
cat > /etc/sysctl.d/90-bmc.conf <<'EOF'
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.tcp_syncookies = 1
EOF

apt-get -y autoremove --purge
apt-get clean
rm -rf /var/lib/apt/lists/*
