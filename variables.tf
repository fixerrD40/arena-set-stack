variable "app_crypto_secret" {
  description = "Base-64 encoded HmacSHA256 key"
  type        = string
}

variable "app_ses_email" {
  description = "The ses-verified personal email address representing the application"
  type        = string
}

variable "aws_access_key_id" {
  description = "AWS IAM access key id"
  type        = string
}

variable "aws_secret_access_key" {
  description = "AWS IAM secret access key"
  type        = string
}

variable "aws_region" {
  description = "AWS region to deploy resources in"
  type        = string
  default     = "us-east-2"
}

variable "frontend_image" {
  description = "Docker image name (including tag) for the frontend"
  type        = string
  default     = "hhmidb/arena-set-cracker-frontend:latest"
}

variable "backend_image" {
  description = "Docker image name (including tag) for the application"
  type        = string
  default     = "hhmidb/arena-set-cracker:latest"
}