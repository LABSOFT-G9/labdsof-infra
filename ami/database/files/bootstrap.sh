#!/bin/bash
# Started by bmc-database.service at every boot.
# 1. mount the MySQL data volume (format it only if it is empty)
# 2. read the database secrets from SSM Parameter Store into /run/bmc (tmpfs)
# 3. start MySQL and mysqld_exporter
# Configuration comes from /etc/bmc/database.env (Terraform user data).
set -euo pipefail
# shellcheck disable=SC1091
source /etc/bmc/database.env

: "${BMC_DATA_VOLUME_ID:?}" "${BMC_PARAMETER_PREFIX:?}" "${AWS_REGION:?}"

MOUNT=/var/lib/bmc-mysql
MYSQL_UID=999       # mysql user in the mysql image
EXPORTER_UID=65534  # nobody, the user of the exporter image

# --- 1. Data volume ---------------------------------------------------------
# On Nitro instances the EBS volume appears as NVMe; its serial is the volume
# ID without the dash. Terraform attaches it after the instance starts, so wait.
device="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${BMC_DATA_VOLUME_ID//-/}"
for _ in $(seq 1 60); do
  [ -e "$device" ] && break
  sleep 5
done
[ -e "$device" ] || { echo "Data volume $BMC_DATA_VOLUME_ID not attached" >&2; exit 1; }

if ! blkid "$device" >/dev/null 2>&1; then
  echo "Formatting empty data volume $BMC_DATA_VOLUME_ID"
  mkfs.ext4 -q -L bmc-mysql "$device"
fi
install -d -m 0755 "$MOUNT"
if ! mountpoint -q "$MOUNT"; then
  uuid=$(blkid -s UUID -o value "$device")
  grep -q "$uuid" /etc/fstab || echo "UUID=$uuid $MOUNT ext4 defaults,nofail 0 2" >> /etc/fstab
  mount "$MOUNT"
fi
install -d -o "$MYSQL_UID" -g "$MYSQL_UID" -m 0750 "$MOUNT/data"

# --- 2. Secrets -------------------------------------------------------------
names=(root_password backup_password exporter_password)
params=$(aws ssm get-parameters --region "$AWS_REGION" --with-decryption \
  --names "${names[@]/#/$BMC_PARAMETER_PREFIX/}" --output json)
missing=$(jq -r '.InvalidParameters | join(", ")' <<<"$params")
[ -z "$missing" ] || { echo "Missing SSM parameters: $missing" >&2; exit 1; }
value() { jq -r --arg n "$BMC_PARAMETER_PREFIX/$1" '.Parameters[] | select(.Name == $n) | .Value' <<<"$params"; }
sql_quote() { printf '%s' "${1//\'/\'\'}"; }

umask 077
rm -rf /run/bmc
install -d -m 0755 /run/bmc /run/bmc/initdb

value root_password > /run/bmc/root_password
value backup_password > /run/bmc/backup_password
chown "$MYSQL_UID" /run/bmc/root_password
chmod 0400 /run/bmc/root_password /run/bmc/backup_password

# Used by MySQL only when the data directory is empty (first start).
cat > /run/bmc/initdb/01-users.sql <<EOF
CREATE USER IF NOT EXISTS 'backup'@'localhost' IDENTIFIED BY '$(sql_quote "$(value backup_password)")';
GRANT SELECT, SHOW VIEW, TRIGGER, LOCK TABLES, EVENT, PROCESS, FLUSH_TABLES ON *.* TO 'backup'@'localhost';
CREATE USER IF NOT EXISTS 'exporter'@'%' IDENTIFIED BY '$(sql_quote "$(value exporter_password)")' WITH MAX_USER_CONNECTIONS 3;
GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO 'exporter'@'%';
EOF
chown -R "$MYSQL_UID" /run/bmc/initdb
chmod 0500 /run/bmc/initdb
chmod 0400 /run/bmc/initdb/01-users.sql

cat > /run/bmc/exporter.my.cnf <<EOF
[client]
user=exporter
password=$(value exporter_password)
EOF
chown "$EXPORTER_UID" /run/bmc/exporter.my.cnf
chmod 0400 /run/bmc/exporter.my.cnf

# --- 3. Containers ----------------------------------------------------------
docker compose -f /opt/bmc/compose.yaml up -d --wait
echo "BMC database started for ${BMC_ENVIRONMENT:-unknown}"
