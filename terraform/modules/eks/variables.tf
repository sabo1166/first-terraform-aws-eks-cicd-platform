variable "cluster_name" {
  description = "Name of the EKS cluster."
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes minor version, e.g. \"1.35\"."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for the control-plane ENIs and the worker nodes."
  type        = list(string)
}

variable "public_access_cidrs" {
  description = "CIDRs allowed to reach the public API endpoint. Required; 0.0.0.0/0 is rejected."
  type        = list(string)

  validation {
    condition     = length(var.public_access_cidrs) > 0 && alltrue([for c in var.public_access_cidrs : can(cidrhost(c, 0))])
    error_message = "public_access_cidrs must be a non-empty list of valid IPv4 CIDRs."
  }
  validation {
    condition     = !contains(var.public_access_cidrs, "0.0.0.0/0") && alltrue([for c in var.public_access_cidrs : tonumber(split("/", c)[1]) > 0])
    error_message = "0.0.0.0/0 (or any /0) is not allowed in public_access_cidrs."
  }
}

variable "cluster_role_arn" {
  description = "ARN of the EKS cluster IAM role."
  type        = string
}

variable "secrets_kms_key_arn" {
  description = "ARN of the KMS key (created in the iam module) used for Kubernetes secrets encryption."
  type        = string
}

variable "node_role_arn" {
  description = "ARN of the worker node IAM role."
  type        = string
}

variable "node_instance_types" {
  description = "Instance types for the managed node group."
  type        = list(string)
}

variable "desired_size" {
  description = "Desired worker node count."
  type        = number
}

variable "min_size" {
  description = "Minimum worker node count."
  type        = number
}

variable "max_size" {
  description = "Maximum worker node count."
  type        = number
}

variable "node_disk_size_gb" {
  description = "Root EBS volume size (GiB) of each worker node."
  type        = number
  default     = 30
}

variable "log_retention_days" {
  description = "Retention in days of the control-plane log group."
  type        = number
  default     = 30
}

variable "additional_access_entries" {
  description = "Extra IAM principals granted cluster access via EKS access entries. A non-empty namespaces list scopes the access policy to those namespaces; empty means cluster-wide."
  type = map(object({
    principal_arn = string
    policy_arn    = string
    namespaces    = optional(list(string), [])
  }))
  default = {}
}
