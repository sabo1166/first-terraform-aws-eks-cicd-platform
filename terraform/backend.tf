# Remote state in S3 with native locking (no DynamoDB table needed).
#
# The bucket is created SEPARATELY by ./bootstrap (which uses local state) and
# must exist before `terraform init` is run here. Backend blocks cannot use
# variables, so the bucket name is injected at init time:
#
#   terraform init -backend-config="bucket=<your-state-bucket>"
#   # or: terraform init -backend-config=backend.hcl   (see backend.hcl.example)
terraform {
  backend "s3" {
    key          = "eks-cicd-platform/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
    # bucket = supplied via -backend-config (never hardcoded here)
  }
}
