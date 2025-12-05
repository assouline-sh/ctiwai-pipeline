variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.micro"
}

variable "opencti_domain" {
  description = "Domain for OpenCTI"
  type        = string
}

variable "opencti_admin_email" {
  description = "Admin email for OpenCTI"
  type        = string
}

variable "opencti_admin_password" {
  description = "Admin password for OpenCTI"
  type        = string
  sensitive   = true
}

variable "opencti_admin_token" {
  description = "Admin API token for OpenCTI"
  type        = string
  sensitive   = true
}

variable "minio_password" {
  description = "Password for Minio"
  type        = string
  sensitive   = true
}

variable "postgres_password" {
  description = "Password for Postgres"
  type        = string
  sensitive   = true
}

variable "rabbitmq_password" {
  description = "Password for RabbitMQ"
  type        = string
  sensitive   = true
}

variable "ssh_public_key" {
  description = "SSH public key"
  type        = string
}

variable "allowed_ssh" {
  description = "IP range allowed to SSH"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}