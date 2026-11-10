# ---------------------------------------------------------------------------
# Admin policy: EC2 / VPC infrastructure administration
#
# These are the broad EC2/VPC write permissions that used to sit in the GitHub
# Actions deploy policy. They are Admin-only. Nothing in this repository
# attaches this policy to any principal: a human administrator attaches it
# (or equivalent permissions, e.g. AdministratorAccess) to their own admin
# role or group outside Terraform. It exists so the required admin permission
# set is reviewable, versioned and reusable, and so CI is provably not given it.
#
# It covers only EC2/VPC. Initial provisioning also needs IAM, KMS, EKS, ECR,
# CloudWatch Logs and S3 administration, which this policy deliberately does
# not duplicate; see docs/OPERATIONS.md "Admin / CI permission boundary".
#
# Everything is limited to var.aws_region. Resource-level scoping is not used
# because VPC/subnet/route/security-group creation cannot be limited by name.
# ---------------------------------------------------------------------------
locals {
  admin_ec2_vpc_policy_name = "${var.project_name}-admin-ec2-vpc"
}

data "aws_iam_policy_document" "admin_ec2_vpc" {
  statement {
    sid       = "Ec2Describe"
    actions   = ["ec2:Describe*"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }

  statement {
    sid = "Ec2VpcAdministration"
    actions = [
      # VPC and subnets
      "ec2:CreateVpc", "ec2:DeleteVpc", "ec2:ModifyVpcAttribute",
      "ec2:CreateSubnet", "ec2:DeleteSubnet", "ec2:ModifySubnetAttribute",
      # Internet and NAT gateways, Elastic IPs
      "ec2:CreateInternetGateway", "ec2:DeleteInternetGateway",
      "ec2:AttachInternetGateway", "ec2:DetachInternetGateway",
      "ec2:AllocateAddress", "ec2:ReleaseAddress",
      "ec2:AssociateAddress", "ec2:DisassociateAddress",
      "ec2:CreateNatGateway", "ec2:DeleteNatGateway",
      # Route tables and routes
      "ec2:CreateRouteTable", "ec2:DeleteRouteTable",
      "ec2:CreateRoute", "ec2:DeleteRoute", "ec2:ReplaceRoute",
      "ec2:AssociateRouteTable", "ec2:DisassociateRouteTable",
      # Security groups
      "ec2:CreateSecurityGroup", "ec2:DeleteSecurityGroup",
      "ec2:AuthorizeSecurityGroupIngress", "ec2:AuthorizeSecurityGroupEgress",
      "ec2:RevokeSecurityGroupIngress", "ec2:RevokeSecurityGroupEgress",
      # Launch templates (node group launch template)
      "ec2:CreateLaunchTemplate", "ec2:CreateLaunchTemplateVersion",
      "ec2:DeleteLaunchTemplate", "ec2:ModifyLaunchTemplate",
      # Tagging
      "ec2:CreateTags", "ec2:DeleteTags",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }
}

resource "aws_iam_policy" "admin_ec2_vpc" {
  name        = local.admin_ec2_vpc_policy_name
  description = "ADMIN ONLY: EC2/VPC administration for the ${var.project_name} stack. Never attach to CI."
  policy      = data.aws_iam_policy_document.admin_ec2_vpc.json
}
