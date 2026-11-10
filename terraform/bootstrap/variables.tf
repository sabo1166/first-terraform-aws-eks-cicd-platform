variable "aws_region" {
  description = "AWS region for the state bucket."
  type        = string
  default     = "us-east-1"
}

variable "state_bucket_name" {
  description = "Globally unique name of the S3 bucket that stores Terraform state. Use the same value for the main configuration's tfstate_bucket_name and its -backend-config bucket."
  type        = string
  default     = "moh-terraform-state-2026-uniq"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.state_bucket_name))
    error_message = "state_bucket_name must be a valid S3 bucket name (3-63 chars, lowercase, digits, hyphens, dots)."
  }
}

variable "noncurrent_version_retention_days" {
  description = "Days to keep noncurrent (previous) state versions before expiry."
  type        = number
  default     = 90
}
