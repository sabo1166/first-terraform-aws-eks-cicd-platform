provider "aws" {
  region = var.aws_region

  # Credentials are never configured here. They come from the standard AWS
  # provider chain: AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY environment
  # variables (GitHub Actions repository secrets), a profile, or OIDC later.
  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "terraform"
    }
  }
}
