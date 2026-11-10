# Permissions for the Terraform deploy identity (user today, OIDC role later).
#
# Admin / CI boundary: this policy holds the day-to-day CI permissions. It has
# resource-scoped permissions for the state bucket, EKS, the control-plane log
# group and ECR; read-only access to IAM, KMS and EC2; and PassRole on exactly the
# two EKS roles. The CREATE-ONLY permissions for first-time provisioning (VPC,
# the two EKS roles behind a permissions boundary, the KMS key, the launch
# template) live in the second policy, github_deploy_create_policy.tf. Everything
# else (the CI user, both CI policies, the boundary, IAM/KMS key policy changes,
# any delete) is Admin-only. See admin_policy.tf for the human admin EC2/VPC set.

locals {
  arn_prefix = "arn:${local.partition}"
  name_glob  = "${var.project_name}-*"
}

data "aws_iam_policy_document" "github_deploy" {
  # --- Terraform state (S3 backend with native locking) --------------------
  statement {
    sid       = "StateBucketList"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = ["${local.arn_prefix}:s3:::${var.tfstate_bucket_name}"]
  }

  statement {
    sid     = "StateObjects"
    actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [
      "${local.arn_prefix}:s3:::${var.tfstate_bucket_name}/${var.tfstate_key}",
      "${local.arn_prefix}:s3:::${var.tfstate_bucket_name}/${var.tfstate_key}.tflock",
    ]
  }

  # --- EC2 / VPC: read here; create-only writes are in the second policy -----
  # Needed so `plan` can refresh the VPC, subnet, NAT, route, security group and
  # launch template resources. There are deliberately NO EC2 write actions in THIS
  # policy; the create-only ones are in github_deploy_create_policy.tf, and there
  # are no Delete*/Release* actions anywhere for CI.
  statement {
    sid       = "Ec2Describe"
    actions   = ["ec2:Describe*"]
    resources = ["*"] # Describe* does not support resource-level scoping
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }

  # --- EKS (scoped to this project's cluster / node group names) -----------
  statement {
    sid       = "EksList"
    actions   = ["eks:ListClusters", "eks:DescribeClusterVersions"]
    resources = ["*"]
  }

  statement {
    sid = "EksManage"
    actions = [
      "eks:CreateCluster", "eks:DeleteCluster", "eks:DescribeCluster",
      "eks:UpdateClusterConfig", "eks:UpdateClusterVersion", "eks:DescribeUpdate",
      "eks:CreateNodegroup", "eks:DeleteNodegroup", "eks:DescribeNodegroup",
      "eks:UpdateNodegroupConfig", "eks:UpdateNodegroupVersion",
      "eks:CreateAccessEntry", "eks:DeleteAccessEntry", "eks:DescribeAccessEntry",
      "eks:UpdateAccessEntry", "eks:ListAssociatedAccessPolicies",
      "eks:AssociateAccessPolicy", "eks:DisassociateAccessPolicy",
      "eks:TagResource", "eks:UntagResource",
    ]
    resources = [
      "${local.arn_prefix}:eks:${var.aws_region}:${local.account_id}:cluster/${local.name_glob}",
      "${local.arn_prefix}:eks:${var.aws_region}:${local.account_id}:nodegroup/${local.name_glob}",
      "${local.arn_prefix}:eks:${var.aws_region}:${local.account_id}:access-entry/${local.name_glob}",
    ]
  }

  # --- IAM roles for EKS: READ-ONLY from CI --------------------------------
  # CI must never be able to create/modify roles, trust policies, inline or
  # attached policies. Any such write (CreateRole, UpdateAssumeRolePolicy,
  # PutRolePolicy, AttachRolePolicy, ...) is a privilege-escalation path: CI
  # could mint a role it can assume with arbitrary permissions. So roles, their
  # policies and the KMS key are changed only by an admin-run apply. CI can
  # still read them (so `plan` can refresh state) and pass them to EKS.
  statement {
    sid = "IamProjectRolesReadOnly"
    actions = [
      "iam:GetRole", "iam:ListRoleTags", "iam:GetRolePolicy",
      "iam:ListRolePolicies", "iam:ListAttachedRolePolicies", "iam:ListInstanceProfilesForRole",
    ]
    resources = ["${local.arn_prefix}:iam::${local.account_id}:role/${local.name_glob}"]
  }

  # PassRole is limited to exactly the EKS cluster role and the node role, and
  # only when handed to EKS. No glob: a future role named <project>-* cannot be
  # passed by CI.
  statement {
    sid     = "IamPassEksRolesToEks"
    actions = ["iam:PassRole"]
    resources = [
      local.eks_cluster_role_arn,
      local.eks_node_role_arn,
    ]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["eks.amazonaws.com"]
    }
  }

  statement {
    sid       = "IamServiceLinkedRoles"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["${local.arn_prefix}:iam::${local.account_id}:role/aws-service-role/*"]
    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values   = ["eks.amazonaws.com", "eks-nodegroup.amazonaws.com", "autoscaling.amazonaws.com"]
    }
  }

  # Read-only on the CI identity itself so plan can refresh it. Changing the
  # CI user/policy is intentionally NOT allowed from CI (no self-escalation).
  statement {
    sid = "IamReadOwnIdentity"
    actions = [
      "iam:GetUser", "iam:ListUserTags", "iam:ListAttachedUserPolicies",
      "iam:ListUserPolicies", "iam:ListGroupsForUser",
      "iam:GetPolicy", "iam:GetPolicyVersion", "iam:ListPolicyVersions", "iam:ListPolicyTags",
    ]
    resources = [
      "${local.arn_prefix}:iam::${local.account_id}:user/ci/${local.github_user_name}",
      "${local.arn_prefix}:iam::${local.account_id}:policy/${local.deploy_policy}",
      "${local.arn_prefix}:iam::${local.account_id}:policy/${local.deploy_create_policy}",
      "${local.arn_prefix}:iam::${local.account_id}:policy/${local.admin_ec2_vpc_policy_name}",
      local.role_boundary_arn,
    ]
  }

  # Read-only so plan can refresh the GitHub OIDC provider (if Terraform manages it).
  statement {
    sid       = "IamReadGithubOidcProvider"
    actions   = ["iam:GetOpenIDConnectProvider", "iam:ListOpenIDConnectProviderTags"]
    resources = ["${local.arn_prefix}:iam::${local.account_id}:oidc-provider/token.actions.githubusercontent.com"]
  }

  # --- KMS: read access plus CreateGrant (EKS requires the caller to be able to
  # create a grant when enabling secrets encryption). Scoped to keys tagged
  # Project=<project_name> (the key ID is unknown until CI creates the key, so the
  # ARN ends in key/*; the tag is the scope). Creating the key is in
  # github_deploy_create_policy.tf; CI can never re-policy or delete a key.
  statement {
    sid = "KmsSecretsKeyUse"
    actions = [
      "kms:DescribeKey", "kms:GetKeyRotationStatus", "kms:GetKeyPolicy",
      "kms:ListResourceTags", "kms:CreateGrant",
    ]
    resources = ["${local.arn_prefix}:kms:${var.aws_region}:${local.account_id}:key/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = [var.project_name]
    }
  }

  statement {
    sid       = "KmsListAliases"
    actions   = ["kms:ListAliases"]
    resources = ["*"] # ListAliases does not support resource-level scoping
  }

  # --- CloudWatch Logs for the control plane (scoped to /aws/eks/<project>-*)
  statement {
    sid = "LogsEksControlPlane"
    actions = [
      "logs:CreateLogGroup", "logs:DeleteLogGroup", "logs:PutRetentionPolicy",
      "logs:DeleteRetentionPolicy", "logs:TagResource", "logs:UntagResource",
      "logs:ListTagsForResource", "logs:ListTagsLogGroup",
    ]
    resources = ["${local.arn_prefix}:logs:${var.aws_region}:${local.account_id}:log-group:/aws/eks/${local.name_glob}"]
  }

  statement {
    sid       = "LogsDescribe"
    actions   = ["logs:DescribeLogGroups"]
    resources = ["*"] # DescribeLogGroups does not support resource-level scoping
  }

  # --- ECR repository (scoped to the single repository) --------------------
  statement {
    sid = "EcrRepositoryManage"
    actions = [
      "ecr:CreateRepository", "ecr:DeleteRepository", "ecr:DescribeRepositories",
      "ecr:PutImageTagMutability", "ecr:PutImageScanningConfiguration",
      "ecr:PutLifecyclePolicy", "ecr:GetLifecyclePolicy", "ecr:DeleteLifecyclePolicy",
      "ecr:GetRepositoryPolicy", "ecr:ListTagsForResource", "ecr:TagResource", "ecr:UntagResource",
    ]
    resources = ["${local.arn_prefix}:ecr:${var.aws_region}:${local.account_id}:repository/${var.ecr_repository_name}"]
  }
}
