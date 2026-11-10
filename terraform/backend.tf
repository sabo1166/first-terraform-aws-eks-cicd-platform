# Remote state in S3 with native locking (no DynamoDB table needed).
#
# The state bucket ALREADY EXISTS: it was created manually in the AWS Console
# (us-east-1). Terraform only uses it here and never creates it, and the
# ./bootstrap configuration is not needed for this bucket (do not run it).
#
# A backend block cannot use variables, so the name is written out below. Keep it
# identical to `tfstate_bucket_name` in variables.tf and to TF_VAR_tfstate_bucket_name
# in .github/workflows/terraform.yml.
terraform {
  backend "s3" {
    bucket       = "moh-terraform-state-2026-unique"
    key          = "eks-cicd-platform/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
