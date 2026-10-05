# =============================================================================
# alb.tf — Public Application Load Balancer
#
# Uses terraform-aws-modules/alb (Anton Babenko).
#
# The ALB terminates plain HTTP on port 80 and forwards to the ECS service.
#
# ---------------------------------------------------------------------------
# Adding HTTPS (recommended for real production use):
#   1. Request and validate an ACM certificate for your domain.
#   2. Replace the `listeners` block below with:
#
#        listeners = {
#          http = {
#            port     = 80
#            protocol = "HTTP"
#            redirect = {
#              port        = "443"
#              protocol    = "HTTPS"
#              status_code = "HTTP_301"
#            }
#          }
#          https = {
#            port            = 443
#            protocol        = "HTTPS"
#            certificate_arn = "arn:aws:acm:REGION:ACCOUNT:certificate/..."
#            forward = {
#              target_group_key = "app"
#            }
#          }
#        }
#
#   3. Create a Route 53 alias record pointing at module.alb.dns_name.
# ---------------------------------------------------------------------------
# =============================================================================

module "alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "~> 10.5"

  name               = "${local.name}-alb"
  load_balancer_type = "application"

  vpc_id          = module.vpc.vpc_id
  subnets         = module.vpc.public_subnets
  security_groups = [module.alb_sg.id]

  enable_deletion_protection = var.enable_deletion_protection
  drop_invalid_header_fields = true
  desync_mitigation_mode     = "defensive"
  idle_timeout               = 60

  listeners = {
    http = {
      port     = 80
      protocol = "HTTP"
      forward = {
        target_group_key = "app"
      }
    }
  }

  target_groups = {
    app = {
      name_prefix          = "app-"
      protocol             = "HTTP"
      port                 = var.container_port
      target_type          = "ip"
      deregistration_delay = 30

      # Targets are registered dynamically by the ECS service (target_type=ip),
      # so no static target group attachment must be created by the ALB module.
      create_attachment = false

      health_check = {
        enabled             = true
        path                = var.health_check_path
        port                = "traffic-port"
        protocol            = "HTTP"
        matcher             = "200"
        interval            = 30
        timeout             = 5
        healthy_threshold   = 2
        unhealthy_threshold = 3
      }
    }
  }

  tags = local.tags
}
