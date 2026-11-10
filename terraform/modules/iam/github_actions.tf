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
