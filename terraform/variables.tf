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
  default = ["10.0.0.0/20", "10.0.16.0/20", "10.0.32.0/20"]
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
  type = string
  # 🔴 SonarQube 를 올리면서 t3.medium → t3.large 로 키웠다.
  #
  #    infra 노드에 이미 올라가는 것 (requests 기준)
  #      argocd 0.5G · prometheus 1.0G · grafana 0.3G · jenkins 2.0G
  #    여기에 SonarQube(JVM + Elasticsearch) 2.0G 와
  #    내장 PostgreSQL 0.3G 가 더해진다 → 약 6.2GB
  #
  #    t3.medium 은 할당 가능이 3.3GB 라 들어가지 않는다.
  default = "t3.large"
}

variable "infra_node_count" {
  type = number
  # 2대로 둔다. SonarQube 가 한 노드를 거의 차지하므로
  # Argo CD · 모니터링 · Jenkins 가 다른 노드를 쓴다.
  default = 2
}

variable "image_tag" {
  type        = string
  default     = ""
}

variable "deploy_app" {
  type        = bool
  default     = true
  description = "true면 terraform apply 한 번으로 이미지 빌드/푸시부터 helm 배포까지 전부 수행한다. 인프라만 먼저 올리고 싶으면 false로 두면 된다."
}

variable "build_images" {
  type        = bool
  default     = true
  description = "true면 docker build/push를 terraform이 직접 실행한다(로컬에 docker, aws cli 필요). 이미 이미지를 다른 방식(CI)으로 push했다면 false로 하고 image_tag를 지정한다."
}

variable "app_source_path" {
  type        = string
  default     = "../../CloudeDX-main"
  description = "dockerfile.backend / dockerfile.crawler / pyproject.toml / uv.lock / alembic / app / web 이 들어있는 CloudDX 소스 루트 경로. terraform/ 디렉터리 기준 상대경로 또는 절대경로."
}

variable "build_platform" {
  type        = string
  default     = "linux/amd64"
  description = "docker build --platform 값. EKS 노드가 x86_64(AL2023_x86_64_STANDARD)이므로 Apple Silicon 등에서 빌드할 때도 amd64로 고정한다."
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

# ---------------------------------------------------------------------------
# SonarQube — 정적 분석 서버
#
# Jenkins 파이프라인의 sonarqube 단계가 이 서버를 호출한다.
# enable_sonarqube = false 로 두면 서버를 만들지 않는다.
# 그때는 Jenkinsfile 의 SONARQUBE_URL 도 비워야 단계가 건너뛰어진다.
# ---------------------------------------------------------------------------
variable "enable_sonarqube" {
  type        = bool
  default     = true
  description = "true면 infra 네임스페이스에 SonarQube 를 배포한다."
}

variable "sonarqube_chart_version" {
  type    = string
  default = "10.7.0+3598"
}

variable "sonarqube_admin_password" {
  type      = string
  default   = ""
  sensitive = true
  description = "비우면 랜덤 생성한다. terraform output 으로 확인한다."
}
