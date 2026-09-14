################
# IAM Policy for Operator (SSM Access)
################

data "aws_caller_identity" "current" {}

resource "aws_iam_policy" "ssm_operator" {
  name        = "${var.project_name}-ssm-operator-policy"
  description = "Policy for Ansible SSM connection - allows sending commands to EC2 instances"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SSMSendCommand"
        Effect = "Allow"
        Action = [
          "ssm:SendCommand",
          "ssm:GetCommandInvocation",
          "ssm:ListCommandInvocations",
          "ssm:DescribeInstanceInformation"
        ]
        Resource = "*"
      },
      {
        Sid    = "EC2DescribeInstances"
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances"
        ]
        Resource = "*"
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-ssm-operator-policy"
  }
}

output "ssm_operator_policy_arn" {
  description = "ARN of the SSM operator policy - attach to your IAM user/group"
  value       = aws_iam_policy.ssm_operator.arn
}
