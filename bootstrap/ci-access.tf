# How CI reaches AWS.
#
# The AWS Organization this account belongs to denies, through a service
# control policy, creating an OIDC provider (so no GitHub OIDC), IAM groups and
# console passwords (so no IAM users for people). What is left:
#
#   bmc-ci      IAM user, no permissions except switching into bmc-admin. Its
#               access key is created by hand (README "First-time setup") and
#               stored only as GitHub secrets, never in Terraform or its state.
#   bmc-admin   AdministratorAccess. Every CI job (plan, apply, destroy)
#               switches into it, for one hour at most.
#
# People work with the account's own sign-in (the Organization's role), not
# with anything created here.

resource "aws_iam_user" "ci" {
  name = "bmc-ci"
}

data "aws_iam_policy_document" "admin_trust" {
  statement {
    # TagSession: aws-actions/configure-aws-credentials tags the session with
    # the repository, workflow and commit, which then shows up in CloudTrail.
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "AWS"
      identifiers = [aws_iam_user.ci.arn]
    }
  }
}

resource "aws_iam_role" "admin" {
  name                 = "bmc-admin"
  assume_role_policy   = data.aws_iam_policy_document.admin_trust.json
  max_session_duration = 3600
}

moved {
  from = aws_iam_role.team["admin"]
  to   = aws_iam_role.admin
}

resource "aws_iam_role_policy_attachment" "admin" {
  role       = aws_iam_role.admin.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

data "aws_iam_policy_document" "ci" {
  statement {
    sid       = "SwitchToAdmin"
    actions   = ["sts:AssumeRole", "sts:TagSession"]
    resources = [aws_iam_role.admin.arn]
  }
}

resource "aws_iam_user_policy" "ci" {
  name   = "switch-to-admin"
  user   = aws_iam_user.ci.name
  policy = data.aws_iam_policy_document.ci.json
}

# Workload roles (for example bmc-<env>-database, see environments/*/main.tf)
# carry this boundary: whatever policy they are given, they can never do more
# than Session Manager and the bmc-* buckets.
data "aws_iam_policy_document" "workload_boundary" {
  statement {
    sid       = "SessionManagerAndRunCommand"
    actions   = ["ssm:*", "ssmmessages:*", "ec2messages:*"]
    resources = ["*"]
  }
  statement {
    sid       = "BmcBuckets"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
    resources = ["arn:aws:s3:::bmc-*", "arn:aws:s3:::bmc-*/*"]
  }
}

resource "aws_iam_policy" "workload_boundary" {
  name        = "bmc-workload-boundary"
  description = "Maximum permissions of any role the deploy roles create." # changing it replaces the policy
  policy      = data.aws_iam_policy_document.workload_boundary.json
}

output "ci_user" {
  description = "Create its access key by hand (README \"First-time setup\") and store it as GitHub secrets."
  value       = aws_iam_user.ci.name
}

output "admin_role_arn" {
  description = "GitHub repository variable AWS_ROLE_ARN."
  value       = aws_iam_role.admin.arn
}
