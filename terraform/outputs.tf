output "vpc_id" {
  description = "ID of the VPC."
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets."
  value       = module.vpc.public_subnet_ids
}

output "private_subnet_ids" {
  description = "IDs of the private subnets (worker nodes)."
  value       = module.vpc.private_subnet_ids
}

output "eks_cluster_name" {
  description = "Name of the EKS cluster."
  value       = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  description = "API server endpoint of the EKS cluster."
  value       = module.eks.cluster_endpoint
}

output "eks_cluster_security_group_id" {
  description = "EKS-managed cluster security group ID."
  value       = module.eks.cluster_security_group_id
}

output "ecr_repository_url" {
  description = "URL of the ECR repository."
  value       = module.ecr.repository_url
}

output "github_actions_user_name" {
  description = "IAM user for GitHub Actions. No access keys are created by Terraform."
  value       = module.iam.github_actions_user_name
}

output "github_ecr_push_role_arn" {
  description = "OIDC role for the workflow's build job (set as the AWS_PUSH_ROLE_ARN repository variable). Null when github_repository is empty."
  value       = module.iam.github_ecr_push_role_arn
}

output "github_eks_deploy_role_arn" {
  description = "OIDC role for the workflow's production deploy job (set as AWS_DEPLOY_ROLE_ARN in the production environment). Null when github_repository is empty."
  value       = module.iam.github_eks_deploy_role_arn
}

output "admin_ec2_vpc_policy_arn" {
  description = "ARN of the admin-only EC2/VPC policy (attach to your admin role/group manually; never to CI)."
  value       = module.iam.admin_ec2_vpc_policy_arn
}

output "github_actions_deploy_policy_arn" {
  description = "ARN of the (separately managed) GitHub Actions Terraform deploy policy."
  value       = module.iam.github_actions_deploy_policy_arn
}
