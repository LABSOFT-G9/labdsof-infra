# GitHub Actions access to AWS without stored keys (OIDC). Three roles, each
# trusted only by this repository's workflows in one situation:
#
#   bmc-github-plan        pull requests and main, no GitHub environment:
#                          read-only, plus the state bucket (state and lock file)
#   bmc-deploy-dev         deploys the infrastructure: jobs in the GitHub environment `dev`
#   bmc-deploy-prod        deploys the infrastructure: jobs in the GitHub environment `prod`
#                          (required reviewers)
#
# The deploy roles are only as safe as the GitHub environments: restrict both to
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
    plan        = ["repo:${var.github_repository}:pull_request", "repo:${var.github_repository}:ref:refs/heads/main"]
    deploy-dev  = ["repo:${var.github_repository}:environment:dev"]
    deploy-prod = ["repo:${var.github_repository}:environment:prod"]
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

  name                 = each.key == "plan" ? "bmc-github-plan" : "bmc-${each.key}"
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
    resources = ["${aws_s3_bucket.state.arn}/dev/*", "${aws_s3_bucket.state.arn}/prod/*"]
  }
  statement {
    sid       = "StateLock"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/dev/*.tflock", "${aws_s3_bucket.state.arn}/prod/*.tflock"]
  }

  # bootstrap/ holds the state of the roles themselves: admins only.
  # (ReadOnlyAccess would otherwise allow reading it.)
  statement {
    sid       = "NoBootstrapState"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = ["${aws_s3_bucket.state.arn}/bootstrap/*"]
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

# --- Deploy roles: least privilege, one environment each --------------------
# A deploy role can only create, change and delete what this repository's
# Terraform manages for ITS environment, in the configured region:
#   EC2/VPC   resources tagged Environment=<env> (tag required when creating)
#   S3        buckets named bmc-<env>-*, and its own state file
#   IAM       roles and instance profiles named bmc-<env>-*, only with the
#             workload permissions boundary, and only AWS's SSM policy attached
# It cannot touch the other environment, other IAM, billing or other services.
# If a future resource needs another permission, the apply fails with
# AccessDenied: add exactly that action here, in a reviewed PR.

locals {
  deploy_envs = { "deploy-dev" = "dev", "deploy-prod" = "prod" }
}

# Workload roles (for example bmc-<env>-database) must carry this boundary:
# whatever policy a deploy role writes into them, they can never do more than
# this. It stops a deploy role from creating an admin role for itself.
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
  description = "Maximum permissions of any role the deploy roles create."
  policy      = data.aws_iam_policy_document.workload_boundary.json
}

data "aws_iam_policy_document" "deploy" {
  for_each = local.deploy_envs

  # Read everything Terraform refreshes (no data, no secrets).
  statement {
    sid       = "Read"
    actions   = ["ec2:Describe*", "ec2:Get*", "iam:Get*", "iam:List*", "s3:ListAllMyBuckets", "sts:GetCallerIdentity"]
    resources = ["*"]
  }

  # Own state file only.
  statement {
    sid       = "StateList"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
  }
  statement {
    sid       = "StateObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/${each.value}/*"]
  }

  # EC2 / VPC: creating requires the Environment tag in the request ...
  statement {
    sid       = "Ec2CreateTagged"
    actions   = ["ec2:Create*", "ec2:RunInstances", "ec2:AllocateAddress", "ec2:AuthorizeSecurityGroupIngress", "ec2:AuthorizeSecurityGroupEgress"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Environment"
      values   = [each.value]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }
  # ... tagging is allowed only as part of that create ...
  statement {
    sid       = "Ec2TagOnCreate"
    actions   = ["ec2:CreateTags"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Environment"
      values   = [each.value]
    }
    condition {
      test     = "Null"
      variable = "ec2:CreateAction"
      values   = ["false"]
    }
  }
  # ... RunInstances also uses the AMI and an untagged network interface ...
  statement {
    sid     = "Ec2RunInstancesShared"
    actions = ["ec2:RunInstances"]
    resources = [
      "arn:aws:ec2:${var.region}::image/*",
      "arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:network-interface/*",
    ]
  }
  # ... and everything else only on resources already tagged with this environment.
  statement {
    sid       = "Ec2ManageTagged"
    actions   = ["ec2:*"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Environment"
      values   = [each.value]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }

  # Never move a resource into another environment by changing its tag.
  statement {
    sid       = "NoRetagToOtherEnvironment"
    effect    = "Deny"
    actions   = ["ec2:CreateTags"]
    resources = ["*"]
    condition {
      test     = "StringNotEquals"
      variable = "aws:RequestTag/Environment"
      values   = [each.value]
    }
    condition {
      test     = "Null"
      variable = "aws:RequestTag/Environment"
      values   = ["false"]
    }
  }
  statement {
    sid       = "NoUntagEnvironment"
    effect    = "Deny"
    actions   = ["ec2:DeleteTags"]
    resources = ["*"]
    condition {
      test     = "ForAnyValue:StringEquals"
      variable = "aws:TagKeys"
      values   = ["Environment"]
    }
  }

  # S3: this environment's buckets only.
  statement {
    sid       = "Buckets"
    actions   = ["s3:*"]
    resources = ["arn:aws:s3:::bmc-${each.value}-*", "arn:aws:s3:::bmc-${each.value}-*/*"]
  }

  # IAM: this environment's workload roles, always with the boundary.
  statement {
    sid       = "WorkloadRolesWithBoundary"
    actions   = ["iam:CreateRole", "iam:PutRolePolicy", "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:DeleteRolePolicy"]
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/bmc-${each.value}-*"]
    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [aws_iam_policy.workload_boundary.arn]
    }
  }
  statement {
    sid = "WorkloadRolesManage"
    actions = [
      "iam:DeleteRole",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:UpdateRole",
      "iam:UpdateAssumeRolePolicy",
    ]
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/bmc-${each.value}-*"]
  }
  statement {
    sid       = "OnlySsmManagedPolicy"
    effect    = "Deny"
    actions   = ["iam:AttachRolePolicy"]
    resources = ["*"]
    condition {
      test     = "ArnNotEquals"
      variable = "iam:PolicyARN"
      values   = ["arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"]
    }
  }
  statement {
    sid       = "KeepBoundary"
    effect    = "Deny"
    actions   = ["iam:DeleteRolePermissionsBoundary", "iam:PutRolePermissionsBoundary"]
    resources = ["*"]
  }
  statement {
    sid = "InstanceProfiles"
    actions = [
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:UntagInstanceProfile",
    ]
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:instance-profile/bmc-${each.value}-*"]
  }
  statement {
    sid       = "PassWorkloadRoleToEc2"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/bmc-${each.value}-*"]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "deploy" {
  for_each = local.deploy_envs

  name   = "bmc-${each.key}"
  role   = aws_iam_role.github[each.key].id
  policy = data.aws_iam_policy_document.deploy[each.key].json
}

output "workload_boundary_arn" {
  value = aws_iam_policy.workload_boundary.arn
}

output "github_role_arns" {
  description = "Set as GitHub variables: plan -> repository variable AWS_PLAN_ROLE_ARN; deploy-dev / deploy-prod -> AWS_DEPLOY_ROLE_ARN on the dev / prod environment."
  value       = { for k, r in aws_iam_role.github : k => r.arn }
}
