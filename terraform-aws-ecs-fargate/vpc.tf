# =============================================================================
# vpc.tf — Network layer (VPC, subnets, NAT) and security groups
#
# Uses the community-maintained terraform-aws-modules/vpc (Anton Babenko) and
# terraform-aws-modules/security-group modules — the de-facto best practice for
# a production-grade AWS network.
#
# Topology:
#   - Two (or three) Availability Zones
#   - Public subnets  : Application Load Balancer + NAT gateway
#   - Private subnets : ECS Fargate tasks + RDS PostgreSQL (no inbound internet)
# =============================================================================

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

################################################################################
# VPC
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.7"

  name = "${local.name}-vpc"
  cidr = var.vpc_cidr

  azs             = slice(data.aws_availability_zones.available.names, 0, var.availability_zone_count)
  private_subnets = [for i in range(var.availability_zone_count) : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i in range(var.availability_zone_count) : cidrsubnet(var.vpc_cidr, 4, i + 8)]

  # Outbound internet access for private subnets (needed by Fargate to pull
  # images from ECR and ship logs to CloudWatch).
  enable_nat_gateway     = true
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = !var.single_nat_gateway

  enable_dns_support   = true
  enable_dns_hostnames = true

  # Tasks/instances in private subnets must not get public IPs.
  map_public_ip_on_launch = false

  # Network traffic visibility / anomaly detection (Trivy AWS-0178).
  enable_flow_log = true

  tags = local.tags
}

################################################################################
# Security groups
#
# NOTE: the ALB egress rule is intentionally "all" rather than restricted to
# the ECS security group. Restricting both directions would create a circular
# dependency between the two security groups at plan time.
################################################################################

# --- Application Load Balancer (public) --------------------------------------
module "alb_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 6.0"

  name        = "${local.name}-alb"
  description = "Public ALB - accepts HTTP/HTTPS from the internet"
  vpc_id      = module.vpc.vpc_id

  ingress_rules = {
    http = {
      description = "HTTP from the internet"
      from_port   = 80
      to_port     = 80
      ip_protocol = "tcp"
      cidr_ipv4   = "0.0.0.0/0"
    }
    https = {
      description = "HTTPS from the internet"
      from_port   = 443
      to_port     = 443
      ip_protocol = "tcp"
      cidr_ipv4   = "0.0.0.0/0"
    }
  }

  egress_rules = {
    all = {
      description = "Allow all outbound traffic to the targets"
      ip_protocol = "-1"
      cidr_ipv4   = "0.0.0.0/0"
    }
  }

  tags = local.tags
}

# --- ECS Fargate tasks (private) ---------------------------------------------
module "ecs_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 6.0"

  name        = "${local.name}-ecs"
  description = "ECS Fargate tasks - application port from the ALB only"
  vpc_id      = module.vpc.vpc_id

  ingress_rules = {
    alb = {
      description                  = "Application port from the ALB"
      from_port                    = var.container_port
      to_port                      = var.container_port
      ip_protocol                  = "tcp"
      referenced_security_group_id = module.alb_sg.id
    }
  }

  egress_rules = {
    all = {
      description = "Allow all outbound (ECR, CloudWatch Logs, RDS)"
      ip_protocol = "-1"
      cidr_ipv4   = "0.0.0.0/0"
    }
  }

  tags = local.tags
}

# --- RDS PostgreSQL (private) -------------------------------------------------
module "rds_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 6.0"

  name        = "${local.name}-rds"
  description = "RDS PostgreSQL - accepts connections from ECS tasks only"
  vpc_id      = module.vpc.vpc_id

  ingress_rules = {
    postgres = {
      description                  = "PostgreSQL from ECS tasks"
      from_port                    = 5432
      to_port                      = 5432
      ip_protocol                  = "tcp"
      referenced_security_group_id = module.ecs_sg.id
    }
  }

  tags = local.tags
}
