# =============================================================================
# ecs.tf — Amazon ECR, ECS Fargate cluster/service and CI/CD IAM
#
# Uses terraform-aws-modules/ecs (Anton Babenko), which creates the cluster,
# task definition, task execution role and the ECS service from a single
# declarative object.
# =============================================================================

################################################################################
# Amazon ECR — container image registry
################################################################################

resource "aws_ecr_repository" "app" {
  name                 = local.name
  image_tag_mutability = var.ecr_image_tag_mutability

  image_scanning_configuration {
    scan_on_push = var.ecr_image_scan_on_push
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = local.tags
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep only the 10 most recent tagged images"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["*"]
          countType      = "imageCountMoreThan"
          countNumber    = 10
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Expire untagged images after 14 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 14
        }
        action = { type = "expire" }
      },
    ]
  })
}

################################################################################
# ECS Fargate cluster + service
################################################################################

module "ecs" {
  source  = "terraform-aws-modules/ecs/aws"
  version = "~> 7.6"

  cluster_name = local.name

  cluster_capacity_providers = ["FARGATE", "FARGATE_SPOT"]
  default_capacity_provider_strategy = {
    FARGATE = {
      weight = 1
      base   = 1
    }
    FARGATE_SPOT = {
      weight = 1
    }
  }

  cloudwatch_log_group_retention_in_days = var.log_retention_in_days

  # The task execution role may read only these secrets.
  task_exec_secret_arns = [
    local.rds_master_secret_arn,
    aws_secretsmanager_secret.app.arn,
  ]

  services = {
    app = {
      name = local.name

      # --- Task definition ---------------------------------------------------
      cpu                      = var.ecs_task_cpu
      memory                   = var.ecs_task_memory
      launch_type              = "FARGATE"
      network_mode             = "awsvpc"
      requires_compatibilities = ["FARGATE"]

      runtime_platform = {
        operating_system_family = "LINUX"
        cpu_architecture        = var.ecs_cpu_architecture
      }

      container_definitions = {
        app = {
          image     = local.container_image
          essential = true

          portMappings = [{
            name          = "http"
            containerPort = var.container_port
            protocol      = "tcp"
          }]

          # Non-secret configuration. Secrets are injected separately below.
          environment = concat(
            [
              { name = "DB", value = "postgres" },
              { name = "DB_HOST", value = module.rds.db_instance_address },
              { name = "DB_PORT", value = "5432" },
              { name = "DB_NAME", value = module.rds.db_instance_name },
              { name = "DB_USER", value = var.db_username },
              { name = "DB_SSLMODE", value = "require" },
              { name = "DEBUG", value = "False" },
              { name = "SITE_ROOT", value = "http://${module.alb.dns_name}" },
              { name = "ALLOWED_HOSTS", value = module.alb.dns_name },
              { name = "WAIT_FOR_DB", value = "true" },
              { name = "RUN_MIGRATIONS", value = "true" },
            ],
            [for k, v in var.django_extra_environment : { name = k, value = v }],
          )

          # Secrets resolved from AWS Secrets Manager at task start-up.
          secrets = [
            {
              name      = "SECRET_KEY"
              valueFrom = "${aws_secretsmanager_secret.app.arn}:SECRET_KEY::"
            },
            {
              name      = "DB_PASSWORD"
              valueFrom = local.db_password_secret_arn
            },
          ]

          readonlyRootFilesystem                 = false
          enable_cloudwatch_logging              = true
          create_cloudwatch_log_group            = true
          cloudwatch_log_group_retention_in_days = var.log_retention_in_days
        }
      }

      # --- Service -----------------------------------------------------------
      desired_count                     = var.ecs_desired_count
      health_check_grace_period_seconds = var.health_check_grace_period

      # The CI/CD pipeline owns task-definition revisions after the initial
      # bootstrap; without this Terraform would revert the image the pipeline
      # deployed back to the bootstrap `:latest` tag.
      ignore_task_definition_changes = true

      deployment_minimum_healthy_percent = 100
      deployment_maximum_percent         = 200
      deployment_circuit_breaker = {
        enable   = true
        rollback = true
      }

      subnet_ids         = module.vpc.private_subnets
      security_group_ids = [module.ecs_sg.id]
      assign_public_ip   = false

      load_balancer = {
        service = {
          target_group_arn = module.alb.target_groups["app"].arn
          container_name   = "app"
          container_port   = var.container_port
        }
      }
    }
  }

  tags = local.tags
}

################################################################################
# CI/CD — GitHub Actions OIDC provider + least-privilege deploy role
#
# Lets the GitHub Actions pipeline assume a role via OIDC (no static keys) to
# push images to ECR and roll the ECS service.
################################################################################

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  # GitHub rotates its certificate; AWS no longer strictly validates the
  # thumbprint, but at least one is required by the API.
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264f70",
  ]

  tags = local.tags
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

locals {
  github_oidc_arn = var.create_github_oidc ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
}

data "aws_iam_policy_document" "github_assume" {
  statement {
    sid     = "AllowGitHubActionsOIDC"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repository}:ref:refs/heads/${var.github_branch}"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = "${local.name}-gha-deploy"
  description        = "GitHub Actions deploy role for ${local.name}"
  assume_role_policy = data.aws_iam_policy_document.github_assume.json

  tags = local.tags
}

data "aws_iam_policy_document" "github_deploy" {
  statement {
    sid       = "ECRAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "ECRPushPull"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
    ]
    resources = [aws_ecr_repository.app.arn]
  }

  statement {
    sid    = "ECSDeploy"
    effect = "Allow"
    actions = [
      "ecs:DescribeClusters",
      "ecs:DescribeServices",
      "ecs:DescribeTaskDefinition",
      "ecs:RegisterTaskDefinition",
      "ecs:UpdateService",
      "ecs:ListServices",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "PassEcsTaskRoles"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "github_deploy" {
  name   = "${local.name}-gha-deploy"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.github_deploy.json
}
