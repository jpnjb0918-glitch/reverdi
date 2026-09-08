variable "region" {
  type    = string
  default = "ap-northeast-2"
}

variable "name" {
  type    = string
  default = "reverdi"
}

variable "kubernetes_version" {
  type    = string
  default = "1.33"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "azs" {
  type    = list(string)
  default = ["ap-northeast-2a", "ap-northeast-2b", "ap-northeast-2c"]
}

variable "public_subnets" {
  type    = list(string)
  default = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
}

variable "private_subnets" {
  type    = list(string)
  default = ["10.0.1.0/20", "10.0.17.0/20", "10.0.33.0/20"]
}

variable "web_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "batch_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "infra_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "image_tag" {
  type        = string
  default     = ""
  description = "ECR image tag. Required when deploy_app=true."
}

variable "deploy_app" {
  type    = bool
  default = false
}

variable "deploy_argocd" {
  type    = bool
  default = true
}

variable "deploy_monitoring" {
  type    = bool
  default = true
}

variable "deploy_jenkins" {
  type    = bool
  default = true
}

variable "domain" {
  type    = string
  default = ""
}

variable "acm_certificate_arn" {
  type    = string
  default = ""
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.small"
}

variable "db_allocated_storage" {
  type    = number
  default = 20
}

variable "tags" {
  type = map(string)
  default = {
    Project = "reverdi"
    Env     = "demo"
  }
}
