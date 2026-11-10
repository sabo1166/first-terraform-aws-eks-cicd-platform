# ---------------------------------------------------------------------------
# EKS cluster role (assumed by the EKS control plane)
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "eks_cluster_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_cluster" {
  name                 = local.eks_cluster_role_name
  assume_role_policy   = data.aws_iam_policy_document.eks_cluster_assume.json
  permissions_boundary = aws_iam_policy.ci_role_boundary.arn
}

resource "aws_iam_role_policy_attachment" "eks_cluster" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}

# ---------------------------------------------------------------------------
# Managed worker node role (assumed by EC2 instances in the node group)
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "eks_node_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_node" {
  name                 = local.eks_node_role_name
  assume_role_policy   = data.aws_iam_policy_document.eks_node_assume.json
  permissions_boundary = aws_iam_policy.ci_role_boundary.arn
}

# Exactly the three AWS-managed policies EKS managed node groups require.
# ECR access is read-only (pull images only).
resource "aws_iam_role_policy_attachment" "eks_node" {
  for_each = local.node_managed_policies

  role       = aws_iam_role.eks_node.name
  policy_arn = each.value
}
