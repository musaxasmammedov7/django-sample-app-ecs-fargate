# =============================================================================
# outputs.tf — Values exposed after `terraform apply`
# =============================================================================

output "application_url" {
  description = "URL at which the application is reachable through the ALB."
  value       = "http://${module.alb.dns_name}"
}

output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer."
  value       = module.alb.dns_name
}

output "alb_arn" {
  description = "ARN of the Application Load Balancer."
  value       = module.alb.arn
}

output "ecr_repository_url" {
  description = "ECR repository URL to push the container image to."
  value       = aws_ecr_repository.app.repository_url
}

output "ecr_repository_name" {
  description = "ECR repository name."
  value       = aws_ecr_repository.app.name
}

output "ecs_cluster_name" {
  description = "Name of the ECS cluster."
  value       = module.ecs.cluster_name
}

output "ecs_service_name" {
  description = "Name of the ECS service."
  value       = module.ecs.services["app"].name
}

output "ecs_task_definition_arn" {
  description = "ARN of the ECS task definition currently used by the service."
  value       = module.ecs.services["app"].task_definition_arn
}

output "rds_endpoint" {
  description = "Connection endpoint of the RDS PostgreSQL instance."
  value       = module.rds.db_instance_endpoint
}

output "rds_address" {
  description = "Hostname of the RDS PostgreSQL instance."
  value       = module.rds.db_instance_address
}

output "rds_master_user_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the RDS master credentials."
  value       = module.rds.db_instance_master_user_secret_arn
  sensitive   = true
}

output "app_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the Django SECRET_KEY."
  value       = aws_secretsmanager_secret.app.arn
  sensitive   = true
}

output "github_actions_role_arn" {
  description = "IAM role ARN GitHub Actions assumes via OIDC (set as the AWS_ROLE_ARN repo variable)."
  value       = aws_iam_role.github_actions.arn
}

output "vpc_id" {
  description = "ID of the created VPC."
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "IDs of the private subnets used by ECS and RDS."
  value       = module.vpc.private_subnets
}

output "public_subnet_ids" {
  description = "IDs of the public subnets used by the ALB."
  value       = module.vpc.public_subnets
}
