locals {
  control_plane_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
}

# ---------------------------------------------------------------------------
# Control-plane logging
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "cluster" {
  # EKS writes to this exact name; creating it first lets us own retention.
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = var.log_retention_days
}

# ---------------------------------------------------------------------------
# Cluster
# ---------------------------------------------------------------------------
resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = var.cluster_role_arn

  enabled_cluster_log_types = local.control_plane_log_types

  vpc_config {
    subnet_ids              = var.private_subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = var.public_access_cidrs
  }

  access_config {
    authentication_mode = "API_AND_CONFIG_MAP"
    # The identity that creates the cluster becomes cluster admin, so a first
    # `kubectl` login works without extra access entries.
    bootstrap_cluster_creator_admin_permissions = true
  }

  encryption_config {
    resources = ["secrets"]

    provider {
      # Key and the cluster role's KMS policy are created in the iam module;
      # the root module's depends_on = [module.iam] orders them before the cluster.
      key_arn = var.secrets_kms_key_arn
    }
  }

  depends_on = [aws_cloudwatch_log_group.cluster]
}

# ---------------------------------------------------------------------------
# Additional cluster access (e.g. the GitHub Actions identity, later)
# ---------------------------------------------------------------------------
resource "aws_eks_access_entry" "additional" {
  for_each = var.additional_access_entries

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value.principal_arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "additional" {
  for_each = var.additional_access_entries

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value.principal_arn
  policy_arn    = each.value.policy_arn

  access_scope {
    type       = length(each.value.namespaces) > 0 ? "namespace" : "cluster"
    namespaces = length(each.value.namespaces) > 0 ? each.value.namespaces : null
  }

  depends_on = [aws_eks_access_entry.additional]
}

# ---------------------------------------------------------------------------
# Worker nodes: managed node group in private subnets
# ---------------------------------------------------------------------------
resource "aws_launch_template" "nodes" {
  name_prefix = "${var.cluster_name}-node-"

  # No security group or key pair is set: nodes use the EKS cluster security
  # group, and there is no SSH access (use SSM/kubectl debug if needed).

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required" # IMDSv2 only
    # Hop limit 1 stops pods (non-hostNetwork) from reaching node credentials.
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = var.node_disk_size_gb
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.cluster_name}-node" }
  }

  tag_specifications {
    resource_type = "volume"
    tags          = { Name = "${var.cluster_name}-node" }
  }
}

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.cluster_name}-default"
  node_role_arn   = var.node_role_arn
  subnet_ids      = var.private_subnet_ids

  instance_types = var.node_instance_types
  ami_type       = "AL2023_x86_64_STANDARD"
  capacity_type  = "ON_DEMAND"

  scaling_config {
    desired_size = var.desired_size
    min_size     = var.min_size
    max_size     = var.max_size
  }

  update_config {
    max_unavailable = 1
  }

  launch_template {
    id      = aws_launch_template.nodes.id
    version = aws_launch_template.nodes.latest_version
  }

  lifecycle {
    # Lets a future cluster autoscaler change the desired count without drift.
    ignore_changes = [scaling_config[0].desired_size]
  }
}
