# S3 buckets for one environment, replacing Garage:
# - attachments: files uploaded with issues (ADR-010), read and written by the app host
# - backups: nightly mysqldump files, written by the database host only
# Both are private, encrypted, versioned and blocked from public access.
# - ansible: short-lived file transfers for Ansible over Session Manager (below)

data "aws_caller_identity" "current" {}

locals {
  # Bucket names are global; the account ID keeps them unique.
  buckets = {
    attachments = "${var.name}-attachments-${data.aws_caller_identity.current.account_id}"
    backups     = "${var.name}-backups-${data.aws_caller_identity.current.account_id}"
  }
}

resource "aws_s3_bucket" "this" {
  for_each = local.buckets

  bucket        = each.value
  force_destroy = var.force_destroy

  # Object Lock can only be switched on when the bucket is created.
  object_lock_enabled = each.key == "backups" && var.backup_lock_days > 0

  tags = { Name = each.value, Purpose = each.key }
}

resource "aws_s3_bucket_public_access_block" "this" {
  for_each = aws_s3_bucket.this

  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Rotation: backups expire after the retention period; replaced or deleted
# versions in both buckets are kept for a short grace period.
resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.this["backups"].id

  rule {
    id     = "expire-old-backups"
    status = "Enabled"
    filter {}

    expiration {
      days = var.backup_retention_days
    }
    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_days
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }

  depends_on = [aws_s3_bucket_versioning.this]
}

resource "aws_s3_bucket_lifecycle_configuration" "attachments" {
  bucket = aws_s3_bucket.this["attachments"].id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_days
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }

  depends_on = [aws_s3_bucket_versioning.this]
}

# Governance mode: a compromised host cannot delete or overwrite a backup
# before the lock expires; an administrator with the bypass permission still can.
resource "aws_s3_bucket_object_lock_configuration" "backups" {
  count  = var.backup_lock_days > 0 ? 1 : 0
  bucket = aws_s3_bucket.this["backups"].id

  rule {
    default_retention {
      mode = "GOVERNANCE"
      days = var.backup_lock_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.this]
}

# Encrypted transport only.
data "aws_iam_policy_document" "tls_only" {
  for_each = aws_s3_bucket.this

  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      each.value.arn,
      "${each.value.arn}/*",
    ]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id
  policy = data.aws_iam_policy_document.tls_only[each.key].json

  depends_on = [aws_s3_bucket_public_access_block.this]
}

# Transfer bucket for Ansible over SSM Session Manager (the community.aws
# aws_ssm connection): Ansible copies files to and from the hosts through it,
# using short-lived presigned URLs created by whoever runs Ansible, so the
# hosts need no permission on it. Files are only needed for seconds: no
# versioning, deleted after a day.
resource "aws_s3_bucket" "ansible" {
  bucket        = "${var.name}-ansible-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = { Name = "${var.name}-ansible-${data.aws_caller_identity.current.account_id}", Purpose = "ansible" }
}

resource "aws_s3_bucket_public_access_block" "ansible" {
  bucket                  = aws_s3_bucket.ansible.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "ansible" {
  bucket = aws_s3_bucket.ansible.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "ansible" {
  bucket = aws_s3_bucket.ansible.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "ansible" {
  bucket = aws_s3_bucket.ansible.id

  rule {
    id     = "expire-transfers"
    status = "Enabled"
    filter {}

    expiration {
      days = 1
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}
