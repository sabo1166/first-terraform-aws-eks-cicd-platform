# ---------------------------------------------------------------------------
# GitHub Actions identity
#
# Today: an IAM user whose access keys YOU create manually and store as the
# repository secrets AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY. Terraform never
# creates or outputs access keys (they would land in state).
#
# Later: switch to GitHub OIDC by assuming a role instead of using a user. The
# permissions live in aws_iam_policy.github_deploy, which is deliberately NOT
# tied to the user, so migrating means attaching the same policy to a role.
# See github_oidc.tf.example.
# ---------------------------------------------------------------------------
resource "aws_iam_user" "github_actions" {
  name = local.github_user_name
  path = "/ci/"
}

resource "aws_iam_policy" "github_deploy" {
  name        = local.deploy_policy
  description = "Permissions for GitHub Actions to plan/apply the ${var.project_name} Terraform stack."
  policy      = data.aws_iam_policy_document.github_deploy.json
}

resource "aws_iam_user_policy_attachment" "github_deploy" {
  user       = aws_iam_user.github_actions.name
  policy_arn = aws_iam_policy.github_deploy.arn
}

# ---------------------------------------------------------------------------
# FULL ADMINISTRATOR ACCESS FOR CI (explicitly authorized by the repository owner)
#
# Attaches the AWS-managed AdministratorAccess policy to THIS user only. Anyone who
# obtains the CI access keys, or who can change the workflow / Terraform code that runs
# with them, then has full administrative control of the whole AWS account.
#
# What still applies: the explicit Deny statements in github_deploy_create_policy.tf
# (no changes to this user, the CI policies, the admin policy or the permissions
# boundary, no new access keys) override AdministratorAccess, because an explicit Deny
# always wins over an Allow. The deploy and create policies stay attached.
#
# Only an administrator can apply this attachment: CI itself is denied
# iam:AttachUserPolicy on its own user. Set grant_ci_administrator_access = false to
# remove it.
# ---------------------------------------------------------------------------
resource "aws_iam_user_policy_attachment" "github_administrator_access" {
  count = var.grant_ci_administrator_access ? 1 : 0

  user       = aws_iam_user.github_actions.name
  policy_arn = "${local.arn_prefix}:iam::aws:policy/AdministratorAccess"
}
