################
# AMI Data Source (Amazon Linux 2023 with SSM preinstalled)
################

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}


################
# Application Instances (2)
################

resource "aws_instance" "app" {
  count                  = 2
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.private[count.index].id
  iam_instance_profile   = aws_iam_instance_profile.ec2_ssm.name
  vpc_security_group_ids = [aws_security_group.app.id]

  tags = {
    Name = "${var.project_name}-app-0${count.index + 1}"
    Role = "webserver"
  }
}

################
# Database Instance (1)
################

resource "aws_instance" "db" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.private[0].id
  iam_instance_profile   = aws_iam_instance_profile.ec2_ssm.name
  vpc_security_group_ids = [aws_security_group.db.id]

  tags = {
    Name = "${var.project_name}-db-01"
    Role = "database"
  }
}