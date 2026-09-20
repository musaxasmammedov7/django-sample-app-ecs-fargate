################
# Outputs
################

output "alb_dns_name" {
  description = "DNS name of the ALB"
  value       = aws_lb.app.dns_name
}

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "app_instance_ids" {
  description = "Instance IDs of app servers"
  value       = aws_instance.app[*].id
}

output "db_instance_id" {
  description = "Instance ID of database server"
  value       = aws_instance.db.id
}

output "app_private_ips" {
  description = "Private IPs of app servers"
  value       = aws_instance.app[*].private_ip
}

output "db_private_ip" {
  description = "Private IP of database server"
  value       = aws_instance.db.private_ip
}

################
# Generate Ansible Inventory File
################

resource "local_file" "inventory" {
  content = <<EOF
[webservers]
${aws_instance.app[0].id} ansible_host=${aws_instance.app[0].private_ip} ansible_user=ec2-user ansible_connection=aws_ssm
${aws_instance.app[1].id} ansible_host=${aws_instance.app[1].private_ip} ansible_user=ec2-user ansible_connection=aws_ssm

[database]
${aws_instance.db.id} ansible_host=${aws_instance.db.private_ip} ansible_user=ec2-user ansible_connection=aws_ssm
EOF
  filename = "${path.module}/../ansible/inventory.ini"
}