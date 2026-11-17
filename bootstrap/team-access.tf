# People's access to the AWS account, with plain IAM (IAM Identity Center
# needs a paid account). Each person has an IAM user with no permissions of
# its own: they sign in with MFA and switch to a role. Roles require MFA and
# last at most one hour.
#
#   bmc-viewonly   see resources, settings, costs and metrics; no data, no secrets
#   bmc-operator   viewonly + start/stop/reboot BMC instances, Session Manager,
#                  read backups and logs; no creating or deleting infrastructure
#   bmc-admin      everything; emergencies only
#
# Passwords and MFA devices are set by each person, never here (README
# "Team access").

variable "team" {
  description = "IAM user name -> access level (admin, operator or viewonly)."
  type        = map(string)
  default = {
    martim  = "admin"
    ricardo = "viewonly"
    pedro   = "viewonly"
    afonso  = "viewonly"
    sandro  = "viewonly"
  }

  validation {
    condition     = alltrue([for level in values(var.team) : contains(["admin", "operator", "viewonly"], level)])
    error_message = "Each access level must be admin, operator or viewonly."
  }
}

locals {
  # Which roles each access level may switch into.
  levels = {
    admin    = ["admin", "operator", "viewonly"]
    operator = ["operator", "viewonly"]
    viewonly = ["viewonly"]
  }
}

# --- Roles -------------------------------------------------------------------

data "aws_iam_policy_document" "team_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
    condition {
      test     = "Bool"
      variable = "aws:MultiFactorAuthPresent"
      values   = ["true"]
    }
  }
}

resource "aws_iam_role" "team" {
  for_each = toset(["admin", "operator", "viewonly"])

  name                 = "bmc-${each.key}"
  assume_role_policy   = data.aws_iam_policy_document.team_trust.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "admin" {
  role       = aws_iam_role.team["admin"].name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_role_policy_attachment" "view_only" {
  for_each = toset(["operator", "viewonly"])

  role       = aws_iam_role.team[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/job-function/ViewOnlyAccess"
}

data "aws_iam_policy_document" "operator" {
  statement {
    sid       = "StartStopBmcInstances"
    actions   = ["ec2:StartInstances", "ec2:StopInstances", "ec2:RebootInstances"]
    resources = ["arn:aws:ec2:*:*:instance/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = ["bmc"]
    }
  }

  statement {
    sid       = "SessionOnBmcInstances"
    actions   = ["ssm:StartSession"]
    resources = ["arn:aws:ec2:*:*:instance/*"]
    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Project"
      values   = ["bmc"]
    }
  }
  statement {
    sid       = "SessionDocument"
    actions   = ["ssm:StartSession"]
    resources = ["arn:aws:ssm:*:*:document/SSM-SessionManagerRunShell"]
  }
  statement {
    sid       = "OwnSessions"
    actions   = ["ssm:TerminateSession", "ssm:ResumeSession"]
    resources = ["arn:aws:ssm:*:*:session/$${aws:userid}-*"]
  }

  statement {
    sid       = "ReadBackups"
    actions   = ["s3:ListBucket", "s3:GetObject"]
    resources = ["arn:aws:s3:::bmc-*-backups-*", "arn:aws:s3:::bmc-*-backups-*/*"]
  }

  statement {
    sid       = "ReadLogs"
    actions   = ["logs:GetLogEvents", "logs:FilterLogEvents", "logs:StartQuery", "logs:GetQueryResults"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "operator" {
  name   = "bmc-operator"
  role   = aws_iam_role.team["operator"].id
  policy = data.aws_iam_policy_document.operator.json
}

# --- Users and groups --------------------------------------------------------

resource "aws_iam_group" "team" {
  for_each = local.levels

  name = "bmc-${each.key}-users"
}

data "aws_iam_policy_document" "group" {
  for_each = local.levels

  statement {
    sid       = "SwitchRole"
    actions   = ["sts:AssumeRole"]
    resources = [for role in each.value : aws_iam_role.team[role].arn]
  }
}

resource "aws_iam_group_policy" "switch_role" {
  for_each = local.levels

  name   = "switch-role"
  group  = aws_iam_group.team[each.key].name
  policy = data.aws_iam_policy_document.group[each.key].json
}

# Everyone may change their own password and manage their own MFA device.
data "aws_iam_policy_document" "self_service" {
  statement {
    sid = "OwnPasswordAndMfa"
    actions = [
      "iam:GetUser",
      "iam:ChangePassword",
      "iam:GetLoginProfile",
      "iam:ListMFADevices",
      "iam:CreateVirtualMFADevice",
      "iam:EnableMFADevice",
      "iam:ResyncMFADevice",
    ]
    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/$${aws:username}",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:mfa/$${aws:username}",
    ]
  }
  statement {
    sid       = "PasswordPolicy"
    actions   = ["iam:GetAccountPasswordPolicy"]
    resources = ["*"]
  }
}

resource "aws_iam_group_policy" "self_service" {
  for_each = local.levels

  name   = "self-service"
  group  = aws_iam_group.team[each.key].name
  policy = data.aws_iam_policy_document.self_service.json
}

resource "aws_iam_user" "team" {
  for_each = var.team

  name          = each.key
  force_destroy = true # also removes the user's MFA device and login profile
}

resource "aws_iam_user_group_membership" "team" {
  for_each = var.team

  user   = aws_iam_user.team[each.key].name
  groups = [aws_iam_group.team[each.value].name]
}

resource "aws_iam_account_password_policy" "this" {
  minimum_password_length        = 14
  require_lowercase_characters   = true
  require_uppercase_characters   = true
  require_numbers                = true
  require_symbols                = true
  allow_users_to_change_password = true
  password_reuse_prevention      = 5
}

output "team_sign_in_url" {
  value = "https://${data.aws_caller_identity.current.account_id}.signin.aws.amazon.com/console"
}

output "team_role_arns" {
  value = { for k, r in aws_iam_role.team : k => r.arn }
}
