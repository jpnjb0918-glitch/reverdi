terraform {
  required_version = ">= 1.11.0"

  # ---------------------------------------------------------------------
  # 상태 백엔드 — S3 + DynamoDB
  #
  # 🔴 지금은 주석 처리했다. 켜려면 두 가지를 먼저 해야 한다.
  #
  #   ① S3 버킷과 DynamoDB 테이블을 만든다
  #      ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
  #
  #      aws s3api create-bucket --bucket reverdi-tfstate-$ACCOUNT \
  #        --region ap-northeast-2 \
  #        --create-bucket-configuration LocationConstraint=ap-northeast-2
  #
  #      aws s3api put-bucket-versioning --bucket reverdi-tfstate-$ACCOUNT \
  #        --versioning-configuration Status=Enabled
  #
  #      aws dynamodb create-table --table-name reverdi-tflock \
  #        --attribute-definitions AttributeName=LockID,AttributeType=S \
  #        --key-schema AttributeName=LockID,KeyType=HASH \
  #        --billing-mode PAY_PER_REQUEST --region ap-northeast-2
  #
  #   ② 아래 주석을 풀고 bucket 에 실제 계정번호를 넣는다
  #   ③ terraform init -migrate-state
  #
  # ⚠️ tfstate 에는 DB 비밀번호가 평문으로 들어간다.
  #    로컬에 두면 .gitignore 로 막고, 팀이면 S3 로 옮긴다.
  # ---------------------------------------------------------------------
  # backend "s3" {
  #   bucket         = "reverdi-tfstate-611669940814"
  #   key            = "eks/terraform.tfstate"
  #   region         = "ap-northeast-2"
  #   dynamodb_table = "reverdi-tflock"
  #   encrypt        = true
  # }
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.62"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.1"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.38"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }
}

provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}
