output "eks_cluster_role_arn" {
  description = "ARN of the EKS cluster IAM role."
  value       = aws_iam_role.eks_cluster.arn
}

output "eks_cluster_role_name" {
  description = "Name of the EKS cluster IAM role."
  value       = aws_iam_role.eks_cluster.name
}

output "eks_secrets_kms_key_arn" {
  description = "ARN of the KMS key used for EKS secrets encryption."
  value       = aws_kms_key.eks_secrets.arn
}

output "eks_node_role_arn" {
  description = "ARN of the EKS worker node IAM role."
  value       = aws_iam_role.eks_node.arn
}

output "github_actions_user_name" {
  description = "Name of the GitHub Actions IAM user (no access keys are created)."
  value       = aws_iam_user.github_actions.name
}

output "github_ecr_push_role_arn" {
  description = "ARN of the OIDC role the build job assumes to push images (null when OIDC is disabled)."
  value       = one(aws_iam_role.github_ecr_push[*].arn)
}

output "github_eks_deploy_role_arn" {
  description = "ARN of the OIDC role the production deploy job assumes (null when OIDC is disabled)."
  value       = one(aws_iam_role.github_eks_deploy[*].arn)
}

output "admin_ec2_vpc_policy_arn" {
  description = "ARN of the ADMIN-ONLY EC2/VPC administration policy. Not attached to any principal by Terraform; never attach to CI."
  value       = aws_iam_policy.admin_ec2_vpc.arn
}

output "ci_role_boundary_arn" {
  description = "ARN of the ADMIN-MANAGED permissions boundary that CI must attach to the EKS cluster and node roles it creates."
  value       = aws_iam_policy.ci_role_boundary.arn
}

output "github_actions_create_policy_arn" {
  description = "ARN of the ADMIN-MANAGED create-only policy for CI initial provisioning."
  value       = aws_iam_policy.github_deploy_create.arn
}

output "github_actions_deploy_policy_arn" {
  description = "ARN of the GitHub Actions Terraform deploy policy."
  value       = aws_iam_policy.github_deploy.arn
}
