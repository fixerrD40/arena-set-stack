terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 6.11.0" }
    random = { source = "hashicorp/random" }
  }
}

provider "aws" {
  region = var.aws_region
}

# 1. VPC + Public Subnet
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
  tags = { Name = "main-vpc" }
}
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
}
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}
resource "aws_route_table" "rt" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}
resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.rt.id
}

# 2. Security Groups
resource "aws_security_group" "ec2_sg" {
  vpc_id = aws_vpc.main.id
  description = "Allow HTTP, SSH"
  ingress {
    from_port = 80
    to_port = 80
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port = 22
    to_port = 22
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "aws_security_group" "db_sg" {
  vpc_id = aws_vpc.main.id
  description = "Allow DB traffic from EC2"
  ingress {
    from_port = 5432
    to_port = 5432
    protocol = "tcp"
    security_groups = [aws_security_group.ec2_sg.id]
  }
  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 3. Aurora PostgreSQL (Minimal)
resource "random_password" "db_master" {
  length  = 16
  special = false
}
resource "aws_db_subnet_group" "aurora_subnets" {
  subnet_ids = [aws_subnet.public.id]
}
resource "aws_rds_cluster" "aurora" {
  cluster_identifier = "app-aurora"
  engine             = "aurora-postgresql"
  master_username    = local.db_user
  master_password    = random_password.db_master.result
  db_subnet_group_name = aws_db_subnet_group.aurora_subnets.name
  vpc_security_group_ids = [aws_security_group.db_sg.id]
}
resource "aws_rds_cluster_instance" "aurora_instance" {
  cluster_identifier = aws_rds_cluster.aurora.id
  instance_class     = "db.t3.micro"
  engine             = aws_rds_cluster.aurora.engine
}

# 4. EC2 Instances (Frontend & Backend)
locals {
  db_user = "admin"

  user_data = <<-EOF
    #!/bin/bash
    yum update -y
    amazon-linux-extras install docker -y
    service docker start    

    docker run -d -p 80:80 ${var.frontend_image}
    docker run -d -p 8080:8080 \
      -e DB_URL=jdbc:postgresql://${aws_rds_cluster.aurora.endpoint}:5432/postgres \
      -e DB_USERNAME=${local.db_user} \
      -e DB_PASSWORD=${random_password.db_master.result} \
      ${var.backend_image}
  EOF
}

resource "aws_instance" "app" {
  ami           = data.aws_ami.amazon_linux.id
  instance_type = "t3.micro"
  subnet_id     = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.ec2_sg.id]
  user_data     = local.user_data

  tags = { Name = "app-instance" }
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

# 5. Outputs
output "frontend_url" {
  description = "Public IP of the frontend"
  value       = aws_instance.app.public_dns
}
output "db_endpoint" {
  description = "Aurora cluster endpoint"
  value       = aws_rds_cluster.aurora.endpoint
}
output "db_master_password" {
  description = "Initial DB master password"
  value       = random_password.db_master.result
  sensitive   = true
}