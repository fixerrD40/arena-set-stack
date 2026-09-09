terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

resource "random_password" "db" {
  length  = 24
  special = false
}

locals {
  name        = "arena-set-stack"
  db_password = random_password.db.result
  # hostname set → https://hostname; empty → http://EIP for first boot.
  public_url  = var.hostname != "" ? "https://${var.hostname}" : "http://${aws_eip.stack.public_ip}"
}

# --- Network (public only; no NAT) ---

resource "aws_vpc" "stack" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = "${local.name}-vpc" }
}

resource "aws_internet_gateway" "stack" {
  vpc_id = aws_vpc.stack.id
  tags   = { Name = "${local.name}-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.stack.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "${var.aws_region}a"
  tags                    = { Name = "${local.name}-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.stack.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.stack.id
  }

  tags = { Name = "${local.name}-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "app" {
  name_prefix = "${local.name}-app-"
  description = "HTTP + HTTPS + SSH"
  vpc_id      = aws_vpc.stack.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_ingress_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "${local.name}-app-sg" }
}

# --- Compute ---

resource "aws_key_pair" "stack" {
  key_name   = "${local.name}-key"
  public_key = var.ssh_public_key
}

resource "aws_eip" "stack" {
  domain = "vpc"
  tags   = { Name = "${local.name}-eip" }
}

resource "aws_instance" "stack" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.app.id]
  key_name                    = aws_key_pair.stack.key_name
  associate_public_ip_address = true

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = templatefile("${path.module}/user-data.sh.tpl", {
    public_url         = local.public_url
    cracker_image      = var.cracker_image
    sharer_image       = var.sharer_image
    db_password        = local.db_password
    app_crypto_secret  = var.app_crypto_secret
    app_mail_username  = var.app_mail_username
    app_mail_password  = var.app_mail_password
    compose_yaml_b64   = base64encode(file("${path.module}/docker-compose.stack.yml"))
  })

  tags = { Name = local.name }

  lifecycle {
    ignore_changes = [ami]
  }
}

resource "aws_eip_association" "stack" {
  instance_id   = aws_instance.stack.id
  allocation_id = aws_eip.stack.id
}

# Nightly EBS snapshot of the root volume (postgres + covers live here via Docker volumes).
resource "aws_dlm_lifecycle_policy" "root_snapshots" {
  description        = "${local.name} root volume snapshots"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]

    target_tags = {
      Name = local.name
    }

    schedule {
      name = "nightly"

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["07:00"]
      }

      retain_rule {
        count = 7
      }

      copy_tags = true
    }
  }

  tags = { Name = "${local.name}-dlm" }
}

# Tag root volume so DLM can find it (instance Name tag is on the instance; volumes need their own).
resource "aws_ec2_tag" "root_volume_name" {
  resource_id = aws_instance.stack.root_block_device[0].volume_id
  key         = "Name"
  value       = local.name
}

resource "aws_iam_role" "dlm" {
  name = "${local.name}-dlm"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "dlm.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "dlm" {
  role       = aws_iam_role.dlm.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

# --- Alerts (EC2 metrics only — no agent / no SSM) ---

resource "aws_sns_topic" "alerts" {
  name = "${local.name}-alerts"
}

resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_metric_alarm" "traffic" {
  alarm_name          = "${local.name}-traffic"
  alarm_description   = "People may be hitting the box — consider real infra (RDS/ALB)."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "NetworkIn"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Sum"
  threshold           = var.traffic_network_in_bytes
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    InstanceId = aws_instance.stack.id
  }
}

resource "aws_cloudwatch_metric_alarm" "status" {
  alarm_name          = "${local.name}-status"
  alarm_description   = "EC2 status check failed."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "StatusCheckFailed"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Maximum"
  threshold           = 1
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    InstanceId = aws_instance.stack.id
  }
}

resource "aws_cloudwatch_metric_alarm" "cpu" {
  alarm_name          = "${local.name}-cpu"
  alarm_description   = "CPU high — box may be too small."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 70
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    InstanceId = aws_instance.stack.id
  }
}

# --- Outputs ---

output "public_url" {
  description = "Public APP_HOST / BASE_URL (https://hostname, or http://EIP if hostname is empty)"
  value       = local.public_url
}

output "eip" {
  description = "Elastic IP (Cloudflare A-record target)"
  value       = aws_eip.stack.public_ip
}

output "instance_id" {
  value = aws_instance.stack.id
}

output "db_password" {
  description = "Generated Postgres password (also on the box compose env)"
  value       = local.db_password
  sensitive   = true
}

output "alert_topic_arn" {
  value = aws_sns_topic.alerts.arn
}
