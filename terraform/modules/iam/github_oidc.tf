# ---------------------------------------------------------------------------
# GitHub OIDC roles for the APPLICATION pipeline (.github/workflows/eks-cicd.yml)
#
# Two separate roles, no long-lived keys:
#   * ecr-push   - assumed by the build job on pushes to the main branch.
#                  Can only push images to the one ECR repository.
#   * eks-deploy - assumed ONLY by jobs that declare `environment: production`
#                  (the OIDC subject contains the environment name, so the role
#                  cannot be assumed until the environment's required reviewer
#                  approves). Can only describe the cluster; Kubernetes access
#                  is granted through an EKS access entry limited to one
#                  namespace (see terraform/main.tf).
#
# Disabled unless var.github_repository is set (nothing is created by default).
# These are IAM writes: they are applied by an administrator, never by CI.
#
# This is separate from the Terraform-management identity in github_actions.tf.
# ---------------------------------------------------------------------------
locals {
  github_oidc_enabled  = var.github_repository != ""
  create_oidc_provider = local.github_oidc_enabled && var.github_oidc_provider_arn == null

  github_oidc_provider_arn = (
    var.github_oidc_provider_arn != null
    ? var.github_oidc_provider_arn
    : one(aws_iam_openid_connect_provider.github[*].arn)
  )

  eks_cluster_arn = "${local.arn_prefix}:eks:${var.aws_region}:${local.account_id}:cluster/${var.cluster_name}"
  ecr_repo_arn    = "${local.arn_prefix}:ecr:${var.aws_region}:${local.account_id}:repository/${var.ecr_repository_name}"
  oidc_host       = "token.actions.githubusercontent.com"
}

# An account can hold only one provider per URL. Pass github_oidc_provider_arn
# to reuse an existing one instead of creating it here.
resource "aws_iam_openid_connect_provider" "github" {
  count = local.create_oidc_provider ? 1 : 0

  url            = "https://${local.oidc_host}"
  client_id_list = ["sts.amazonaws.com"]
}

# --- Build role: push images to ECR from the main branch -------------------
data "aws_iam_policy_document" "github_push_assume" {
  count = local.github_oidc_enabled ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Exact match on repository and branch: no wildcards, so pull requests and
    # other branches cannot assume this role.
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = ["repo:${var.github_repository}:ref:refs/heads/${var.github_main_branch}"]
    }
  }
}

data "aws_iam_policy_document" "github_push" {
  count = local.github_oidc_enabled ? 1 : 0

  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # GetAuthorizationToken does not support resource-level scoping
  }

  # Push only. No pull/list/delete, no repository or lifecycle administration.
  # (The repository uses immutable tags, so existing tags cannot be overwritten.)
  statement {
    sid = "EcrPushToOneRepository"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:DescribeImages",
    ]
    resources = [local.ecr_repo_arn]
  }
}

resource "aws_iam_role" "github_ecr_push" {
  count = local.github_oidc_enabled ? 1 : 0

  name                 = "${var.project_name}-gha-ecr-push"
  description          = "GitHub Actions build job: push images to ${var.ecr_repository_name} from ${var.github_main_branch}."
  assume_role_policy   = data.aws_iam_policy_document.github_push_assume[0].json
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "github_ecr_push" {
  count = local.github_oidc_enabled ? 1 : 0

  name   = "ecr-push"
  role   = aws_iam_role.github_ecr_push[0].id
  policy = data.aws_iam_policy_document.github_push[0].json
}

# --- Deploy role: only after the production environment is approved --------
data "aws_iam_policy_document" "github_deploy_assume" {
  count = local.github_oidc_enabled ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    # The subject is only issued for jobs that reference this environment, which
    # GitHub holds until a required reviewer approves.
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = ["repo:${var.github_repository}:environment:${var.github_deploy_environment}"]
    }
  }
}

data "aws_iam_policy_document" "github_deploy_app" {
  count = local.github_oidc_enabled ? 1 : 0

  # Needed by `aws eks update-kubeconfig`. Kubernetes authorization is separate
  # (EKS access entry, namespace-scoped), so this grants no cluster changes.
  statement {
    sid       = "DescribeCluster"
    actions   = ["eks:DescribeCluster"]
    resources = [local.eks_cluster_arn]
  }

  # Lets the deploy job confirm the approved image digest exists before applying.
  statement {
    sid       = "VerifyImageExists"
    actions   = ["ecr:DescribeImages"]
    resources = [local.ecr_repo_arn]
  }
}

resource "aws_iam_role" "github_eks_deploy" {
  count = local.github_oidc_enabled ? 1 : 0

  name                 = "${var.project_name}-gha-eks-deploy"
  description          = "GitHub Actions deploy job (production environment): deploy to EKS ${var.cluster_name}."
  assume_role_policy   = data.aws_iam_policy_document.github_deploy_assume[0].json
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "github_eks_deploy" {
  count = local.github_oidc_enabled ? 1 : 0

  name   = "eks-deploy"
  role   = aws_iam_role.github_eks_deploy[0].id
  policy = data.aws_iam_policy_document.github_deploy_app[0].json
}
