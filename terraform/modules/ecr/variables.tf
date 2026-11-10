variable "repository_name" {
  description = "Name of the ECR repository."
  type        = string
}

variable "untagged_retention_days" {
  description = "Days after which untagged images are expired."
  type        = number
  default     = 14
}
