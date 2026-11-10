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
}
