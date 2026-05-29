variable "aws_region" {
  default = "us-east-1"
}

variable "key_pair_name" {
  description = "Nombre del key pair existente en AWS para acceso SSH"
  type        = string
}

variable "github_repo_url" {
  description = "URL HTTPS del repo público con el código"
  type        = string
}

variable "resource_prefix" {
  default = "ba"
}
