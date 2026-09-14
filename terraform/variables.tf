################
#   Variables  #
################

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "eu-north-1"
}

variable "project_name" {
  description = "Project name for resource naming"
  type        = string
  default     = "django-healthcheck"
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets"
  type        = list(string)
  default     = ["10.0.3.0/24", "10.0.4.0/24"]
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.micro"
}

variable "db_name" {
  description = "PostgreSQL database name"
  type        = string
  default     = "hc"
}

variable "db_user" {
  description = "PostgreSQL username"
  type        = string
  default     = "hc_user"
}

variable "db_password" {
  description = "PostgreSQL password (set in terraform.tfvars - no default!)"
  type        = string
  sensitive   = true
}

variable "github_repo" {
  description = "GitHub repo URL for the app"
  type        = string
  default     = "https://github.com/musaxasmammedov7/django-sample-app.git"
}

variable "github_branch" {
  description = "Branch to clone"
  type        = string
  default     = "main"
}
