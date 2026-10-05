# =============================================================================
# providers.tf — Terraform & provider configuration
# =============================================================================

terraform {
  required_version = ">= 1.11.1"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.28"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }

  # Remote state is a production best practice (shared, locked, encrypted).
  # Configure the bucket/table below or pass them at init time with
  # `terraform init -backend-config=...`. Left disabled by default so the
  # project can be evaluated locally without an S3 bucket.
  #
  # backend "s3" {
  #   bucket       = "my-tf-state-bucket"
  #   key          = "django-sample-app/ecs-fargate/terraform.tfstate"
  #   region       = "eu-north-1"
  #   encrypt      = true
  #   use_lockfile = true
  # }
}

provider "aws" {
  region = var.aws_region

  # Applied to every taggable resource that does not define these tags itself.
  default_tags {
    tags = local.tags
  }
}
