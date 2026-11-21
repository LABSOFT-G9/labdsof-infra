# How the application repository (LABSOFT-G9/LABDSOF_G9A) deploys to dev.
#
# Its deploy job signs in as the IAM user bmc-deploy-dev (access key stored
# only as secrets of that repository's `dev` environment, created by hand,
# never in Terraform or its state) and runs bmc-app-deploy on the dev
# application host through SSM Run Command. The user can do nothing else:
#   - send AWS-RunShellScript, only to instances tagged Environment=dev and
#     Role=app (the dev application host);
#   - read the result of its commands;
#   - list instances, to find that host and the edge host's public IP.
# A command runs as root on that host, so the key controls the dev
# application host: keep it in the `dev` environment, limited to main.

resource "aws_iam_user" "deploy_dev" {
  name = "bmc-deploy-dev"
}

data "aws_iam_policy_document" "deploy_dev" {
  statement {
    sid       = "RunCommandOnDevAppHost"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:instance/*"]
    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Environment"
      values   = ["dev"]
    }
    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Role"
      values   = ["app"]
    }
  }
  statement {
    sid       = "OnlyTheShellScriptDocument"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ssm:${var.region}::document/AWS-RunShellScript"]
  }
  statement {
    sid       = "ReadCommandResults"
    actions   = ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations", "ssm:ListCommands"]
    resources = ["*"]
  }
  statement {
    sid       = "FindHosts"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }
}

resource "aws_iam_user_policy" "deploy_dev" {
  name   = "deploy-dev"
  user   = aws_iam_user.deploy_dev.name
  policy = data.aws_iam_policy_document.deploy_dev.json
}

output "deploy_dev_user" {
  description = "Create its access key by hand and store it in the application repository's dev environment (README \"Application deploy\")."
  value       = aws_iam_user.deploy_dev.name
}
