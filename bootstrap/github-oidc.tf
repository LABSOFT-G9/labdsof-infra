# GitHub Actions access to AWS without stored keys (OIDC). Three roles, each
# trusted only by this repository's workflows in one situation:
#
#   bmc-github-plan        pull requests and main, no GitHub environment:
#                          read-only, plus the state bucket (state and lock file)
#   bmc-github-apply-dev   jobs in the GitHub environment `dev`
#   bmc-github-apply-prod  jobs in the GitHub environment `prod` (required reviewers)
#
# The apply roles are only as safe as the GitHub environments: restrict both to
# the `main` branch (README "GitHub settings"), or a branch could deploy.

variable "github_repository" {
  description = "owner/name of the repository whose workflows may assume the roles."
  type        = string
  default     = "LABSOFT-G9/labdsof-infra"
}

locals {
  oidc_host = "token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://${local.oidc_host}"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_policy_document" "trust" {
  for_each = {
    plan       = ["repo:${var.github_repository}:pull_request", "repo:${var.github_repository}:ref:refs/heads/main"]
    apply-dev  = ["repo:${var.github_repository}:environment:dev"]
    apply-prod = ["repo:${var.github_repository}:environment:prod"]
  }

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = each.value
    }
  }
}

resource "aws_iam_role" "github" {
  for_each = data.aws_iam_policy_document.trust

  name                 = "bmc-github-${each.key}"
  assume_role_policy   = each.value.json
  max_session_duration = 3600
}

# --- Plan role: read everything Terraform refreshes, write only the state ---

resource "aws_iam_role_policy_attachment" "plan_read_only" {
  role       = aws_iam_role.github["plan"].name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "plan" {
  statement {
    sid       = "StateBucket"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
  }

  # Read the state; write and delete only the lock files (use_lockfile).
  statement {
    sid       = "StateRead"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.state.arn}/*"]
  }
  statement {
    sid       = "StateLock"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/*.tflock"]
  }

  # ReadOnlyAccess would also let pull-request code read data and secrets.
  statement {
    sid       = "NoDataOrSecrets"
    effect    = "Deny"
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = ["arn:aws:s3:::bmc-*-attachments-*/*", "arn:aws:s3:::bmc-*-backups-*/*"]
  }
  statement {
    sid       = "NoSecretValues"
    effect    = "Deny"
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath", "secretsmanager:GetSecretValue", "kms:Decrypt"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "plan" {
  name   = "bmc-github-plan"
  role   = aws_iam_role.github["plan"].id
  policy = data.aws_iam_policy_document.plan.json
}

# --- Apply roles -------------------------------------------------------------
# AdministratorAccess: the configuration creates IAM roles, VPCs, instances and
# buckets, so a narrower policy would need constant upkeep. Each role is
# limited by its trust policy to one GitHub environment, and `prod` requires a
# reviewer. Narrowing these policies is a follow-up (US-22-02).

resource "aws_iam_role_policy_attachment" "apply_admin" {
  for_each = toset(["apply-dev", "apply-prod"])

  role       = aws_iam_role.github[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

output "github_role_arns" {
  description = "Set as GitHub variables: plan -> repository variable AWS_PLAN_ROLE_ARN; apply-dev / apply-prod -> AWS_APPLY_ROLE_ARN on the dev / prod environment."
  value       = { for k, r in aws_iam_role.github : k => r.arn }
}
