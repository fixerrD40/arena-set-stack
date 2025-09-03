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