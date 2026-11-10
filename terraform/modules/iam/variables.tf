variable "project_name" {
  description = "Project prefix. Roles created by CI must be named '<project_name>-*'."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name; used to name the secrets-encryption KMS key and the cluster role's inline KMS policy."
  type        = string
}

variable "aws_region" {
  description = "Region the GitHub Actions deploy policy is restricted to."
  type        = string
}

variable "tfstate_bucket_name" {
  description = "Terraform state bucket the deploy policy may read/write."
  type        = string
}

variable "tfstate_key" {
  description = "State object key (the .tflock lock object is derived from it)."
  type        = string
}

variable "ecr_repository_name" {
  description = "ECR repository the deploy policy may manage."
  type        = string
}

variable "github_repository" {
  description = "GitHub repository (\"owner/name\") allowed to assume the application pipeline roles via OIDC. Empty disables the OIDC roles."
  type        = string
  default     = ""
}

variable "github_main_branch" {
  description = "Only pushes to this branch may assume the ECR push role."
  type        = string
  default     = "main"
}

variable "github_deploy_environment" {
  description = "GitHub Environment name whose jobs may assume the deploy role."
  type        = string
  default     = "production"
}

variable "github_oidc_provider_arn" {
  description = "ARN of an existing GitHub OIDC provider in this account. Null creates one (an account can have only one per URL)."
  type        = string
  default     = null
}

variable "grant_ci_administrator_access" {
  description = "Attach the AWS-managed AdministratorAccess policy to the GitHub Actions IAM user (full AWS administrative access for CI). The explicit self-protection Deny statements in the CI policies still apply."
  type        = bool
  default     = false
}

variable "github_actions_user_name" {
  description = "Override for the GitHub Actions IAM user name. Defaults to '<project_name>-github-actions'."
  type        = string
  default     = null
}
