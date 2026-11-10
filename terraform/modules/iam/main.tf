data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id

  # AWS-managed policies the node role is allowed to have attached.
  node_managed_policies = {
    worker = "arn:${local.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy"
    cni    = "arn:${local.partition}:iam::aws:policy/AmazonEKS_CNI_Policy"
    ecr_ro = "arn:${local.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  }

  github_user_name = coalesce(var.github_actions_user_name, "${var.project_name}-github-actions")
  deploy_policy    = "${var.project_name}-github-actions-deploy"

  # Second CI policy (create-only EC2/IAM-role/KMS permissions). Kept separate because a
  # managed policy is limited to 6,144 characters.
  deploy_create_policy = "${var.project_name}-github-actions-create"

  # Names are built from variables (never from resource attributes) so the CI policies
  # and the permissions boundary do not depend on resources that CI itself creates. This
  # lets an administrator apply the admin-only layer (CI user, CI policies, boundary)
  # BEFORE CI creates the roles, KMS key and network.
  eks_cluster_role_name = "${var.project_name}-eks-cluster-role"
  eks_node_role_name    = "${var.project_name}-eks-node-role"
  role_boundary_name    = "${var.project_name}-eks-role-boundary"
  kms_alias_name        = "alias/${var.cluster_name}-secrets"

  eks_cluster_role_arn = "${local.arn_prefix}:iam::${local.account_id}:role/${local.eks_cluster_role_name}"
  eks_node_role_arn    = "${local.arn_prefix}:iam::${local.account_id}:role/${local.eks_node_role_name}"
  role_boundary_arn    = "${local.arn_prefix}:iam::${local.account_id}:policy/${local.role_boundary_name}"

  # The only AWS-managed policies CI may attach to the two EKS roles.
  eks_role_managed_policy_arns = concat(
    ["${local.arn_prefix}:iam::aws:policy/AmazonEKSClusterPolicy"],
    values(local.node_managed_policies),
  )
}
