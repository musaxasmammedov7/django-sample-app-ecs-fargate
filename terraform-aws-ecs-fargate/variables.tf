# =============================================================================
# variables.tf — Input variables and shared locals
# =============================================================================

################################################################################
# General
################################################################################

variable "aws_region" {
  description = "AWS region in which all resources are created."
  type        = string
  default     = "eu-north-1"
}

variable "project_name" {
  description = "Base name used for every resource (cluster, ALB, ECR, RDS, ...)."
  type        = string
  default     = "django-sample-app"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,29}$", var.project_name))
    error_message = "project_name must be 2-30 lowercase alphanumeric/hyphen characters and start with a letter."
  }
}

variable "environment" {
  description = "Deployment environment name (used in tags)."
  type        = string
  default     = "prod"
}

################################################################################
# Networking
################################################################################

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block."
  }
}

variable "availability_zone_count" {
  description = "Number of Availability Zones to spread subnets across."
  type        = number
  default     = 2

  validation {
    condition     = var.availability_zone_count >= 2 && var.availability_zone_count <= 3
    error_message = "availability_zone_count must be 2 or 3 for a highly available setup."
  }
}

variable "single_nat_gateway" {
  description = "Use a single NAT gateway (cheaper) instead of one per AZ (more resilient)."
  type        = bool
  default     = true
}

################################################################################
# Container image / ECR
################################################################################

variable "container_image" {
  description = "Full container image URI. When empty, the ECR repository created by this stack is used with var.image_tag."
  type        = string
  default     = ""
}

variable "image_tag" {
  description = "Image tag to deploy when container_image is not set explicitly."
  type        = string
  default     = "latest"
}

variable "ecr_image_tag_mutability" {
  description = "Whether image tags can be overwritten (MUTABLE) or are immutable (IMMUTABLE)."
  type        = string
  default     = "MUTABLE"

  validation {
    condition     = contains(["MUTABLE", "IMMUTABLE"], var.ecr_image_tag_mutability)
    error_message = "ecr_image_tag_mutability must be MUTABLE or IMMUTABLE."
  }
}

variable "ecr_image_scan_on_push" {
  description = "Enable ECR basic vulnerability scanning on every push."
  type        = bool
  default     = true
}

################################################################################
# ECS / Fargate
################################################################################

variable "ecs_task_cpu" {
  description = "Fargate task CPU units (256, 512, 1024, 2048, 4096)."
  type        = number
  default     = 512
}

variable "ecs_task_memory" {
  description = "Fargate task memory in MiB."
  type        = number
  default     = 1024
}

variable "ecs_desired_count" {
  description = "Number of tasks the ECS service should run."
  type        = number
  default     = 1
}

variable "ecs_cpu_architecture" {
  description = "Fargate CPU architecture. Use ARM64 (Graviton) for lower cost, X86_64 for maximum compatibility."
  type        = string
  default     = "X86_64"

  validation {
    condition     = contains(["X86_64", "ARM64"], var.ecs_cpu_architecture)
    error_message = "ecs_cpu_architecture must be X86_64 or ARM64."
  }
}

variable "container_port" {
  description = "Port the application listens on inside the container."
  type        = number
  default     = 8000
}

variable "health_check_path" {
  description = "HTTP path used by the ALB target group health check."
  type        = string
  default     = "/api/v3/status/"
}

variable "health_check_grace_period" {
  description = "Seconds the ECS service ignores ALB health checks after a task starts."
  type        = number
  default     = 60
}

################################################################################
# Database (RDS PostgreSQL)
################################################################################

variable "db_name" {
  description = "Name of the initial PostgreSQL database."
  type        = string
  default     = "hc"
}

variable "db_username" {
  description = "Master username for the PostgreSQL instance."
  type        = string
  default     = "hc"
}

variable "db_engine_version" {
  description = "PostgreSQL engine version."
  type        = string
  default     = "16.4"
}

variable "db_family" {
  description = "DB parameter group family (must match the engine version)."
  type        = string
  default     = "postgres16"
}

variable "db_major_engine_version" {
  description = "DB option group major engine version."
  type        = string
  default     = "16"
}

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.micro"
}

variable "db_allocated_storage" {
  description = "Initial allocated storage in GiB."
  type        = number
  default     = 20
}

variable "db_max_allocated_storage" {
  description = "Upper limit for RDS storage autoscaling in GiB."
  type        = number
  default     = 100
}

variable "db_multi_az" {
  description = "Enable a Multi-AZ standby for the database."
  type        = bool
  default     = false
}

variable "db_backup_retention_period" {
  description = "Number of days automated backups are retained."
  type        = number
  default     = 7
}

variable "db_deletion_protection" {
  description = "Protect the database from accidental deletion."
  type        = bool
  default     = false
}

variable "db_skip_final_snapshot" {
  description = "Skip the final snapshot when the database is destroyed (true only for non-production)."
  type        = bool
  default     = true
}

################################################################################
# Load balancing / TLS
################################################################################

variable "enable_deletion_protection" {
  description = "Enable deletion protection on the Application Load Balancer."
  type        = bool
  default     = false
}

################################################################################
# Application runtime configuration
################################################################################

variable "django_extra_environment" {
  description = "Additional non-secret environment variables passed to the container (name => value)."
  type        = map(string)
  default     = {}
}

variable "log_retention_in_days" {
  description = "CloudWatch Logs retention for the ECS service and cluster."
  type        = number
  default     = 30
}

################################################################################
# CI/CD (GitHub Actions OIDC)
################################################################################

variable "create_github_oidc" {
  description = "Create a GitHub Actions OIDC provider + deploy role (set false if one already exists in the account)."
  type        = bool
  default     = true
}

variable "github_repository" {
  description = "GitHub repository allowed to assume the deploy role, in owner/name form."
  type        = string
  default     = "musaxasmammedov7/django-sample-app"
}

variable "github_branch" {
  description = "Branch allowed to assume the deploy role."
  type        = string
  default     = "main"
}

################################################################################
# Locals
################################################################################

locals {
  name = var.project_name

  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Component   = "django-sample-app-ecs-fargate"
  }

  # Resolve the image URI: an explicit override, otherwise the ECR repo this
  # stack manages. Referencing the ECR repository resource here is what lets
  # Terraform create the repository before the ECS service.
  container_image = (
    var.container_image != ""
    ? var.container_image
    : "${aws_ecr_repository.app.repository_url}:${var.image_tag}"
  )

  # The RDS-managed master secret ARN is marked sensitive by the RDS module.
  # The ARN itself is not a secret, and the ECS module needs it as a plain
  # string for its `for_each`, so it is explicitly de-sensitised here.
  rds_master_secret_arn  = nonsensitive(module.rds.db_instance_master_user_secret_arn)
  db_password_secret_arn = "${local.rds_master_secret_arn}:password::"
}
