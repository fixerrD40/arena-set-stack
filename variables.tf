variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-2"
}

variable "instance_type" {
  description = "EC2 instance type (t3.small recommended for nginx+JVM+Postgres)"
  type        = string
  default     = "t3.small"
}

variable "alert_email" {
  description = "SNS destination for traffic / health / CPU alarms"
  type        = string
  sensitive   = true
}

variable "app_crypto_secret" {
  description = "Base64 APP_CRYPTO_SECRET (same as local sharer .env)"
  type        = string
  sensitive   = true
}

variable "app_mail_username" {
  description = "Gmail SMTP From address"
  type        = string
  sensitive   = true
}

variable "app_mail_password" {
  description = "Gmail app password"
  type        = string
  sensitive   = true
}

variable "ssh_ingress_cidr" {
  description = "CIDR allowed to SSH (use your /32)"
  type        = string
}

variable "ssh_public_key" {
  description = "SSH public key material for the instance key pair"
  type        = string
}

variable "hostname" {
  description = "DNS name or IP for the public site (no scheme). Becomes APP_HOST https://hostname. Empty = http://EIP."
  type        = string
  default     = ""
}

variable "cracker_image" {
  description = "Docker Hub image for the Angular/nginx client"
  type        = string
  default     = "hhmidb/arena-set-cracker:latest"
}

variable "sharer_image" {
  description = "Docker Hub image for the Spring API"
  type        = string
  default     = "hhmidb/arena-set-sharer:latest"
}

variable "traffic_network_in_bytes" {
  description = "NetworkIn Sum (bytes / 5 min) that means real traffic; alarm after 3 periods"
  type        = number
  default     = 5000000
}
