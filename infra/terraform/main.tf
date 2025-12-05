terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Get latest Ubuntu AMI
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

# VPC
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "opencti-vpc"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "opencti-igw"
  }
}

# Public Subnet
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true

  tags = {
    Name = "opencti-subnet"
  }
}

# Route Table
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "opencti-rt"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Security Group
resource "aws_security_group" "opencti" {
  name        = "opencti-sg"
  description = "Security group for OpenCTI"
  vpc_id      = aws_vpc.main.id

  # SSH
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh
  }

  # OpenCTI Web Interface
  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Outbound internet access
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "opencti-sg"
  }
}

# SSH Key
resource "aws_key_pair" "opencti" {
  key_name   = "opencti-key"
  public_key = var.ssh_public_key
}

# Data Volume
resource "aws_ebs_volume" "data" {
  availability_zone = "${var.aws_region}a"
  size              = 50
  type              = "gp3"
  encrypted         = true

  tags = {
    Name = "opencti-data"
  }
}

# EC2 Instance
resource "aws_instance" "opencti" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = var.instance_type
  key_name      = aws_key_pair.opencti.key_name
  subnet_id     = aws_subnet.public.id
  
  vpc_security_group_ids = [aws_security_group.opencti.id]

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = templatefile("${path.module}/user_data.sh", {
    OPENCTI_DOMAIN      = var.opencti_domain
    ADMIN_EMAIL         = var.opencti_admin_email
    OPENCTI_PASSWORD    = var.opencti_admin_password
    OPENCTI_TOKEN       = var.opencti_admin_token
    MINIO_PASSWORD      = var.minio_password
    POSTGRES_PASSWORD   = var.postgres_password
    RABBITMQ_PASSWORD   = var.rabbitmq_password
  })

  tags = {
    Name = "opencti-server"
  }
}

# Attach Data Volume
resource "aws_volume_attachment" "data" {
  device_name = "/dev/xvdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.opencti.id
}

# Elastic IP
resource "aws_eip" "opencti" {
  domain   = "vpc"
  instance = aws_instance.opencti.id

  tags = {
    Name = "opencti-eip"
  }

  depends_on = [aws_internet_gateway.main]
}

# IAM Role for EC2
resource "aws_iam_role" "opencti_ec2" {
  name_prefix = "opencti-ec2-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "opencti-ec2-role"
  }
}

# IAM Instance Profile
resource "aws_iam_instance_profile" "opencti" {
  name_prefix = "opencti-ec2-"
  role        = aws_iam_role.opencti_ec2.name

  tags = {
    Name = "opencti-instance-profile"
  }
}

# Attach CloudWatch policy for logs
resource "aws_iam_role_policy_attachment" "cloudwatch" {
  role       = aws_iam_role.opencti_ec2.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# Outputs
output "public_ip" {
  value = aws_eip.opencti.public_ip
}

output "opencti_url" {
  value = "http://${aws_eip.opencti.public_ip}:8080"
}

output "ssh_command" {
  value = "ssh -i ~/.ssh/opencti-key ubuntu@${aws_eip.opencti.public_ip}"
}
