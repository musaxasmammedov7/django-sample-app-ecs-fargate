# =============================================================================
# db.tf — RDS PostgreSQL + application secrets
#
# Uses terraform-aws-modules/rds (Anton Babenko).
#
# The database master password is generated and stored by AWS Secrets Manager
# (`manage_master_user_password = true`), so it never appears in Terraform
# state or output. The Django SECRET_KEY is generated with the random provider
# and stored in a separate Secrets Manager secret.
# =============================================================================

module "rds" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 7.2"

  identifier = "${local.name}-pg"

  engine               = "postgres"
  engine_version       = var.db_engine_version
  family               = var.db_family
  major_engine_version = var.db_major_engine_version
  instance_class       = var.db_instance_class

  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_allocated_storage
  storage_encrypted     = true

  db_name  = var.db_name
  username = var.db_username
  port     = "5432"

  # AWS manages (and can rotate) the master password in Secrets Manager.
  manage_master_user_password = true

  multi_az                   = var.db_multi_az
  deletion_protection        = var.db_deletion_protection
  skip_final_snapshot        = var.db_skip_final_snapshot
  backup_retention_period    = var.db_backup_retention_period
  apply_immediately          = true
  auto_minor_version_upgrade = true

  # Networking — private subnets, reachable only from the ECS security group.
  create_db_subnet_group = true
  subnet_ids             = module.vpc.private_subnets
  vpc_security_group_ids = [module.rds_sg.id]

  # Ship PostgreSQL logs to CloudWatch.
  create_cloudwatch_log_group     = true
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  parameters = [
    { name = "log_connections", value = "1" },
    { name = "log_disconnections", value = "1" },
  ]

  tags = local.tags
}

################################################################################
# Application secret (Django SECRET_KEY)
################################################################################

resource "random_password" "django_secret_key" {
  length           = 64
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_secretsmanager_secret" "app" {
  name        = "${local.name}/django"
  description = "Django runtime secrets for ${local.name}"

  # 0 days recovery makes destroy/create cycles painless for a demo project.
  # Use 7-30 days in a real production account.
  recovery_window_in_days = 0

  tags = local.tags
}

resource "aws_secretsmanager_secret_version" "app" {
  secret_id = aws_secretsmanager_secret.app.id

  secret_string = jsonencode({
    SECRET_KEY = random_password.django_secret_key.result
  })
}
