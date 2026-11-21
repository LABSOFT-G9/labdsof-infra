# Database host runbook

Applies to `dev` and `prod`; replace `<env>` and `<account>`. Commands assume admin AWS credentials and region `eu-north-1`.

## Secrets

Create them before the first `terraform apply` of an environment. The host fails to start MySQL if any is missing. Use generated passwords without single quotes.

```
for p in root_password backup_password exporter_password; do
  aws ssm put-parameter --type SecureString \
    --name "/bmc/<env>/database/$p" \
    --value "$(openssl rand -base64 30 | tr -d \"'/+=\")"
done
```

They are read at every boot into `/run/bmc` (memory only). The MySQL users `backup` and `exporter` are created from them on the **first** start, when the data volume is empty. To rotate a password later, change it in MySQL (`ALTER USER`) and in SSM, then restart `bmc-database.service`.

## Connect

No SSH. Use Session Manager:

```
aws ssm start-session --target "$(terraform -chdir=environments/<env> output -raw database_instance_id)"
sudo systemctl status bmc-database bmc-backup.timer
sudo docker compose -f /opt/bmc/compose.yaml ps
```

## Build a new AMI version

1. Change what is needed (`ansible/roles/…`, for example a new image digest in `ansible/roles/database/files/compose.yaml`), through a PR.
2. Build (dev must be applied; prerequisites in README "Building the database image"): `packer init ami/database && packer build -var version=<new> ami/database`.
3. **dev** picks the newest build on its next `terraform apply` (the instance is replaced, the data volume is kept).
4. **prod**: change `database_ami_version` in `environments/prod/terraform.tfvars` in a PR, review the plan, apply.

## Backups

- Nightly at 02:00 UTC (`bmc-backup.timer`), to `s3://bmc-<env>-backups-<account>/mysql/<env>/<timestamp>.sql.gz`.
- Manual backup: `sudo systemctl start bmc-backup.service`, then `journalctl -u bmc-backup.service`.
- Retention: 7 days in dev, 30 in prod (lifecycle rule). Object Lock is off in both while they are short-lived (README "Environments").
- The host can only write new backups; listing, reading and restoring need admin credentials.

## Restore (exercise at least once, NFR-09)

1. Choose a backup: `aws s3 ls s3://bmc-<env>-backups-<account>/mysql/<env>/`.
2. Copy it to the host, or stream it through a session:
   ```
   aws s3 cp s3://bmc-<env>-backups-<account>/mysql/<env>/<file>.sql.gz - | gunzip \
     | sudo docker exec -i -e MYSQL_PWD="$(sudo cat /run/bmc/root_password)" bmc-mysql mysql -uroot
   ```
   (On the host, the restore needs read access to the backup, which the host role does not have: run the `aws s3 cp` with admin credentials, or copy the file first.)
3. Check row counts and integrity against the source, and record the result as evidence.

The dump includes the `mysql` system schema, so users and grants are restored as they were at backup time.

## Replace the host

`terraform apply` after an AMI change replaces the instance. The data volume is detached and reattached; MySQL starts on the existing data. Take a manual backup first in prod.

Destroying an environment (README "Lifecycle") deletes its backups bucket too: download any backup you want to keep first.

## Not covered yet

- EBS snapshots of the data volume (Data Lifecycle Manager), in addition to the logical backups.
- Alerts on a failed backup (US-20).
