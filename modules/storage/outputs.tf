output "attachments_bucket" {
  value = aws_s3_bucket.this["attachments"].id
}

output "attachments_bucket_arn" {
  value = aws_s3_bucket.this["attachments"].arn
}

output "backups_bucket" {
  value = aws_s3_bucket.this["backups"].id
}

output "backups_bucket_arn" {
  value = aws_s3_bucket.this["backups"].arn
}

output "ansible_bucket" {
  description = "Transfer bucket for Ansible over Session Manager (ansible_aws_ssm_bucket_name)."
  value       = aws_s3_bucket.ansible.id
}
