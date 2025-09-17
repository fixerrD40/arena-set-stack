terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 6.11.0" }
    random = { source = "hashicorp/random" }
  }
}

provider "aws" {
  region = var.aws_region
}

# 1. VPC and Subnets
resource "aws_vpc" "main" {
  cidr_block            = "10.0.0.0/16"
  enable_dns_hostnames  = true

  tags                  = { Name = "main-vpc" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "us-east-2a"
  tags = { Name = "public-subnet" }
}

resource "aws_subnet" "private" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  map_public_ip_on_launch = false
  availability_zone       = "us-east-2a"
  tags = { Name = "private-subnet" }
}

resource "aws_subnet" "private_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.3.0/24"
  map_public_ip_on_launch = false
  availability_zone       = "us-east-2b"
  tags = { Name = "private-subnet-b" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route_table_association" "private_assoc" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private_rt.id
}

resource "aws_route_table_association" "private_assoc_b" {
  subnet_id      = aws_subnet.private_b.id
  route_table_id = aws_route_table.private_rt.id
}

# 2. Security Groups
resource "aws_security_group" "ec2_sg" {
  vpc_id      = aws_vpc.main.id
  description = "Allow HTTP and SSH"

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "db_sg" {
  vpc_id      = aws_vpc.main.id
  description = "Allow DB traffic from EC2"

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 3. RDS PostgreSQL
resource "random_password" "db_master" {
  length  = 16
  special = false
}

resource "aws_db_subnet_group" "private_db_subnet" {
  name = "private-db-subnet"
  subnet_ids = [
    aws_subnet.private.id,
    aws_subnet.private_b.id
  ]

  tags = {
    Name = "private-db-subnet"
  }
}

resource "aws_db_instance" "postgres" {
  identifier              = "my-postgres-db"
  engine                  = "postgres"
  instance_class          = "db.t3.micro"
  username                = local.db_user
  password                = random_password.db_master.result
  allocated_storage       = 20
  max_allocated_storage   = 100
  db_subnet_group_name    = aws_db_subnet_group.private_db_subnet.name
  vpc_security_group_ids  = [aws_security_group.db_sg.id]
  publicly_accessible     = false
  skip_final_snapshot     = true
  deletion_protection     = false

  tags = {
    Name = "my-postgres-db"
  }
}

# 4. EC2 Instance
locals {
  db_user = "db_admin"

  user_data = <<-EOF
    #!/bin/bash
    exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1
    yum update -y
    amazon-linux-extras install docker -y
    service docker start

    PUBLIC_HOSTNAME=$(curl -s http://169.254.169.254/latest/meta-data/public-hostname)
    docker run -d --network host -p 80:80 -e BASE_URL="http://$PUBLIC_HOSTNAME" ${var.frontend_image}
    docker run -d --network host -p 8080:8080 \
      -e APP_CRYPTO_SECRET="${var.app_crypto_secret}" \
      -e APP_HOST="http://$PUBLIC_HOSTNAME" \
      -e APP_SES_EMAIL="${var.app_ses_email}" \
      -e AWS_ACCESS_KEY_ID="${var.aws_access_key_id}" \
      -e AWS_SECRET_ACCESS_KEY="${var.aws_secret_access_key}" \
      -e DB_URL="jdbc:postgresql://${aws_db_instance.postgres.address}:5432/postgres" \
      -e DB_USERNAME="${local.db_user}" \
      -e DB_PASSWORD="${random_password.db_master.result}" \
      ${var.backend_image}
  EOF
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

resource "aws_instance" "app" {
  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.ec2_sg.id]
  user_data                   = local.user_data

  tags                        = { Name = "app-instance" }
}

# 5. SES Email Identity
resource "aws_ses_email_identity" "personal_email" {
  email = var.app_ses_email
}

# 6. Outputs
output "frontend_url" {
  description = "Public IP of the frontend"
  value       = aws_instance.app.public_dns
}

output "db_endpoint" {
  description = "RDS PostgreSQL endpoint"
  value       = aws_db_instance.postgres.address
}

output "db_master_password" {
  description = "Initial DB master password"
  value       = random_password.db_master.result
  sensitive   = true
}