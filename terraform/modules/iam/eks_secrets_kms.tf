# ---------------------------------------------------------------------------
# KMS key for EKS envelope encryption of Kubernetes Secrets, and the inline
# policy that lets the cluster role use it.
#
# Lives in the iam module (not the eks module) so that every IAM/KMS write is
# in one admin-applied place, and so the CI deploy policy can be scoped to this
# exact key. It cannot be applied by the GitHub Actions identity.
# ---------------------------------------------------------------------------
resource "aws_kms_key" "eks_secrets" {
  description             = "EKS secrets encryption for ${var.cluster_name}"
  enable_key_rotation     = true
  deletion_window_in_days = 7
}

resource "aws_kms_alias" "eks_secrets" {
  name          = "alias/${var.cluster_name}-secrets"
  target_key_id = aws_kms_key.eks_secrets.key_id
}

data "aws_iam_policy_document" "eks_cluster_kms" {
  statement {
    sid       = "UseSecretsKey"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:ListGrants", "kms:DescribeKey"]
    resources = [aws_kms_key.eks_secrets.arn]
  }
}

resource "aws_iam_role_policy" "eks_cluster_kms" {
  name   = "${var.cluster_name}-secrets-kms"
  role   = aws_iam_role.eks_cluster.id
  policy = data.aws_iam_policy_document.eks_cluster_kms.json
}
