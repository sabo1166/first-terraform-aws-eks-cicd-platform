output "state_bucket_name" {
  description = "Name of the Terraform state bucket. Pass to the main config via -backend-config and TF_VAR_tfstate_bucket_name."
  value       = aws_s3_bucket.state.id
}

output "state_bucket_arn" {
  description = "ARN of the Terraform state bucket."
  value       = aws_s3_bucket.state.arn
}

output "backend_init_command" {
  description = "Command to initialize the main configuration against this bucket."
  value       = "terraform init -backend-config=\"bucket=${aws_s3_bucket.state.id}\""
}
