# ---------------------------------------------------------------------------
# Permissions boundary for the two EKS roles (ADMIN-MANAGED)
#
# GitHub Actions may create the EKS cluster role and node role, but ONLY with this
# boundary attached (the CI policy requires iam:PermissionsBoundary = this policy, and
# denies removing it). A boundary grants nothing; it is the ceiling on what those roles
# can ever do, even if someone later adds an inline policy to them. So CI cannot mint
# an administrator role: anything outside this list is denied for the two roles.
#
# This policy itself is admin-only: CI has no write access to it (see the explicit
# deny in github_deploy_create_policy.tf; an approved plan that includes it would fail at
# apply). An administrator must apply it BEFORE CI creates the roles.
#
# Unavoidable wildcards (all documented, all only a ceiling):
#   ec2:*, elasticloadbalancing:*  The AWS-managed EKS policies (cluster, CNI, worker)
#                                  use many ec2/elb actions that are updated by AWS over
#                                  time; an exact list would break the cluster whenever AWS
#                                  adds one. Limited to var.aws_region.
#   kms:...  on key/*              The key ARN is not known before the key exists. Limited
#                                  to keys tagged Project=<project_name>.
#   ecr:GetAuthorizationToken      Cannot be scoped to a resource (AWS requirement).
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "ci_role_boundary" {
  statement {
    sid       = "Ec2AndLoadBalancersForEks"
    actions   = ["ec2:*", "elasticloadbalancing:*"]
    resources = ["*"] # see header: AWS-managed EKS policies, ceiling only
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }

  statement {
    sid       = "AutoScalingAndMetricsRead"
    actions   = ["autoscaling:Describe*", "cloudwatch:PutMetricData"]
    resources = ["*"] # Describe*/PutMetricData do not support resource-level scoping
  }

  statement {
    sid = "SecretsKeyUse"
    actions = [
      "kms:Encrypt", "kms:Decrypt", "kms:ListGrants", "kms:DescribeKey", "kms:CreateGrant",
    ]
    resources = ["${local.arn_prefix}:kms:${var.aws_region}:${local.account_id}:key/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = [var.project_name]
    }
  }

  statement {
    sid       = "EcrPullOnly"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # not resource-scopable
  }

  # Nodes must also pull the EKS add-on images (vpc-cni/aws-node, kube-proxy, CoreDNS,
  # pause) from AWS-owned ECR registries in other accounts. Limiting pulls to this
  # project's repository left the CNI unable to start, so nodes never became Ready
  # (NodeCreationFailure). Read-only pull actions, any repository, this region only.
  statement {
    sid = "EcrPullForNodes"
    actions = [
      "ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer",
      "ecr:DescribeImages", "ecr:DescribeRepositories", "ecr:ListImages",
    ]
    resources = ["${local.arn_prefix}:ecr:${var.aws_region}:*:repository/*"]
  }

  statement {
    sid       = "EksDescribeCluster"
    actions   = ["eks:DescribeCluster"]
    resources = ["${local.arn_prefix}:eks:${var.aws_region}:${local.account_id}:cluster/${var.cluster_name}"]
  }

  statement {
    sid       = "ServiceLinkedRolesForEks"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["${local.arn_prefix}:iam::${local.account_id}:role/aws-service-role/*"]
    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values   = ["eks.amazonaws.com", "eks-nodegroup.amazonaws.com", "elasticloadbalancing.amazonaws.com", "autoscaling.amazonaws.com"]
    }
  }
}

resource "aws_iam_policy" "ci_role_boundary" {
  name        = local.role_boundary_name
  description = "ADMIN ONLY: permissions boundary (ceiling) for the EKS cluster and node roles that CI may create. Never edit from CI."
  policy      = data.aws_iam_policy_document.ci_role_boundary.json
}
