variable "project_name" {
  description = "Name prefix for all resources. Also used to scope the GitHub Actions IAM policy (resources named '<project_name>-*')."
  type        = string
  default     = "eks-cicd-platform"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,29}$", var.project_name))
    error_message = "project_name must be 3-30 chars, lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "CIDR block of the VPC."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block."
  }
}

variable "availability_zones" {
  description = "Two availability zones, in the same order as the subnet lists."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]

  validation {
    condition     = length(var.availability_zones) == 2 && length(distinct(var.availability_zones)) == 2
    error_message = "Exactly two distinct availability zones are required."
  }
}

variable "public_subnets" {
  description = "Public subnet CIDRs, one per availability zone (same order)."
  type        = list(string)
  default     = ["10.0.0.0/24", "10.0.1.0/24"]

  validation {
    condition     = length(var.public_subnets) == 2 && alltrue([for c in var.public_subnets : can(cidrhost(c, 0))])
    error_message = "Provide exactly two valid public subnet CIDRs."
  }
}

variable "private_subnets" {
  description = "Private subnet CIDRs, one per availability zone (same order). Worker nodes run here."
  type        = list(string)
  default     = ["10.0.16.0/20", "10.0.32.0/20"]

  validation {
    condition     = length(var.private_subnets) == 2 && alltrue([for c in var.private_subnets : can(cidrhost(c, 0))])
    error_message = "Provide exactly two valid private subnet CIDRs."
  }
}

variable "kubernetes_version" {
  description = "EKS Kubernetes minor version. Check the EKS version calendar: 1.34 leaves standard support 2026-12-02; 1.35 runs to 2027-03-27."
  type        = string
  default     = "1.35"

  validation {
    condition     = can(regex("^1\\.[0-9]{2}$", var.kubernetes_version))
    error_message = "kubernetes_version must look like \"1.35\"."
  }
}

variable "public_access_cidrs" {
  description = "REQUIRED. CIDR blocks allowed to reach the public EKS API endpoint (e.g. [\"203.0.113.10/32\"]). 0.0.0.0/0 is rejected."
  type        = list(string)

  validation {
    condition     = length(var.public_access_cidrs) > 0
    error_message = "public_access_cidrs must contain at least one CIDR."
  }
  validation {
    condition     = alltrue([for c in var.public_access_cidrs : can(cidrhost(c, 0))])
    error_message = "Every entry in public_access_cidrs must be a valid IPv4 CIDR (e.g. 203.0.113.10/32)."
  }
  validation {
    condition     = !contains(var.public_access_cidrs, "0.0.0.0/0") && alltrue([for c in var.public_access_cidrs : tonumber(split("/", c)[1]) > 0])
    error_message = "0.0.0.0/0 (or any /0) is not allowed in public_access_cidrs."
  }
}

variable "node_instance_types" {
  description = "Instance types for the managed node group."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "desired_size" {
  description = "Desired number of worker nodes."
  type        = number
  default     = 2
}

variable "min_size" {
  description = "Minimum number of worker nodes."
  type        = number
  default     = 2
}

variable "max_size" {
  description = "Maximum number of worker nodes."
  type        = number
  default     = 3

  validation {
    condition     = var.max_size >= var.desired_size && var.desired_size >= var.min_size && var.min_size >= 1
    error_message = "Sizes must satisfy 1 <= min_size <= desired_size <= max_size."
  }
}

variable "ecr_repository_name" {
  description = "Name of the private ECR repository."
  type        = string
  default     = "first-k8s-project"
}

variable "log_retention_days" {
  description = "Retention (days) for the EKS control-plane CloudWatch log group."
  type        = number
  default     = 30
}

variable "tfstate_bucket_name" {
  description = "Name of the existing Terraform state bucket (created manually in the AWS Console). Must match the bucket in backend.tf. Used only to scope the GitHub Actions deploy policy."
  type        = string
  default     = "moh-terraform-state-2026-unique"
}

variable "tfstate_key" {
  description = "State object key. Must match the key in backend.tf. Used only to scope the GitHub Actions deploy policy."
  type        = string
  default     = "eks-cicd-platform/terraform.tfstate"
}

variable "additional_access_entries" {
  description = "Extra IAM principals to grant EKS cluster access (map key = label). policy_arn e.g. arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy. Optional namespaces limits the policy to those namespaces."
  type = map(object({
    principal_arn = string
    policy_arn    = string
    namespaces    = optional(list(string), [])
  }))
  default = {}
}

variable "github_repository" {
  description = "GitHub repository (\"owner/name\") whose workflow may assume the OIDC push/deploy roles. Leave empty to create no OIDC roles."
  type        = string
  default     = ""

  validation {
    condition     = var.github_repository == "" || can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "github_repository must be empty or look like \"owner/name\" (no wildcards)."
  }
}

variable "github_oidc_provider_arn" {
  description = "ARN of an existing GitHub OIDC provider in this account; null makes Terraform create one."
  type        = string
  default     = null
}

variable "kubernetes_namespace" {
  description = "Namespace the production deploy role may modify (created by an admin with kubectl; not managed by Terraform)."
  type        = string
  default     = "first-k8s-project"
}
