#!/bin/bash
# Nightly logical backup (bmc-backup.timer): mysqldump of every database,
# compressed and streamed to s3://<backups bucket>/mysql/<environment>/.
# The host may only add objects there; rotation is the bucket's lifecycle rule.
set -euo pipefail
# shellcheck disable=SC1091
source /etc/bmc/database.env

: "${BMC_BACKUPS_BUCKET:?}" "${BMC_ENVIRONMENT:?}" "${AWS_REGION:?}"

key="mysql/${BMC_ENVIRONMENT}/$(date -u +%Y-%m-%dT%H%M%SZ).sql.gz"

docker exec -e MYSQL_PWD="$(cat /run/bmc/backup_password)" bmc-mysql \
  mysqldump --user=backup --single-transaction --routines --triggers --events \
  --all-databases \
  | gzip -9 \
  | aws s3 cp - "s3://${BMC_BACKUPS_BUCKET}/${key}" --region "$AWS_REGION" --only-show-errors

echo "Backup written to s3://${BMC_BACKUPS_BUCKET}/${key}"
