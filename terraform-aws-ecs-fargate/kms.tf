# =============================================================================
# kms.tf — Customer Managed Key (CMK) for encryption at rest
#
# Used to encrypt:
#   - the ECR repository (image layers)      -> addresses Trivy AWS-0033
#   - the application Secrets Manager secret -> addresses Trivy AWS-0098
#
# The RDS-managed master secret stays on the AWS-managed key because RDS owns
# its lifecycle; the RDS instance itself is encrypted with the RDS-managed key
# by default (storage_encrypted = true).
#
# Key rotation is enabled; the default key policy delegates administration to
# the account root, and IAM policies grant scoped use to the ECS task
# execution role (see ecs.tf).
# =============================================================================

resource "aws_kms_key" "main" {
  description             = "CMK for ${local.name} (ECR + Secrets Manager)"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = local.tags
}

resource "aws_kms_alias" "main" {
  name          = "alias/${local.name}"
  target_key_id = aws_kms_key.main.key_id
}
