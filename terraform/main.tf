locals {
  cluster_name = "${var.project_name}-eks"

  # The production deploy role gets namespace-scoped "edit" access to ONE
  # namespace (not cluster-admin). Only present when the OIDC roles are enabled.
  github_deploy_access_entry = var.github_repository == "" ? {} : {
    github_deploy = {
      principal_arn = module.iam.github_eks_deploy_role_arn
      policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"
      namespaces    = [var.kubernetes_namespace]
    }
  }
}

module "vpc" {
  source = "./modules/vpc"

  name               = var.project_name
  cluster_name       = local.cluster_name
  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones
  public_subnets     = var.public_subnets
  private_subnets    = var.private_subnets
}

module "iam" {
  source = "./modules/iam"

  project_name        = var.project_name
  cluster_name        = local.cluster_name
  aws_region          = var.aws_region
  tfstate_bucket_name = var.tfstate_bucket_name
  tfstate_key         = var.tfstate_key
  ecr_repository_name = var.ecr_repository_name

  github_repository        = var.github_repository
  github_oidc_provider_arn = var.github_oidc_provider_arn
}

module "ecr" {
  source = "./modules/ecr"

  repository_name = var.ecr_repository_name
}

module "eks" {
  source = "./modules/eks"

  cluster_name              = local.cluster_name
  kubernetes_version        = var.kubernetes_version
  private_subnet_ids        = module.vpc.private_subnet_ids
  public_access_cidrs       = var.public_access_cidrs
  cluster_role_arn          = module.iam.eks_cluster_role_arn
  secrets_kms_key_arn       = module.iam.eks_secrets_kms_key_arn
  node_role_arn             = module.iam.eks_node_role_arn
  node_instance_types       = var.node_instance_types
  desired_size              = var.desired_size
  min_size                  = var.min_size
  max_size                  = var.max_size
  log_retention_days        = var.log_retention_days
  additional_access_entries = merge(var.additional_access_entries, local.github_deploy_access_entry)

  # Role policy attachments live in the iam module and are not referenced by
  # attribute, so make the ordering explicit (EKS fails if they are missing).
  depends_on = [module.iam]
}
