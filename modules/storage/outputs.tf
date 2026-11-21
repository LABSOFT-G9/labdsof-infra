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
