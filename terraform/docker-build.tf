# ---------------------------------------------------------------------------
# docker-build.tf
#
# 목적: "terraform apply" 한 번으로 끝나게 만든다.
#
# 기존에는
#   1) terraform apply (deploy_app=false)
#   2) docker build/push를 손으로
#   3) image_tag를 손으로 넣고 terraform apply (deploy_app=true)
# 이렇게 2번 나눠서 해야 했다.
#
# 여기서는 ECR repository가 만들어진 다음, 같은 apply 안에서
#   - CloudDX 소스(app_source_path)의 내용을 해시해서 image tag를 계산하고
#   - docker build / ecr push를 null_resource + local-exec로 실행하고
#   - 그 태그를 곧바로 helm_release.app 에 넘긴다.
#
# 전제 조건 (terraform을 실행하는 머신 기준)
#   - docker, aws cli가 설치되어 있고 PATH에 있어야 한다
#   - docker desktop/daemon이 켜져 있어야 한다
#   - aws 자격증명(ecr get-login-password 권한 포함)이 설정되어 있어야 한다
#   - var.app_source_path 가 CloudDX 소스 루트(=dockerfile.backend가 있는 위치)를 가리켜야 한다
# ---------------------------------------------------------------------------

locals {
  # 이미지 내용에 실제로 영향을 주는 파일만 골라 해시한다.
  # (docker-compose*, docs, demo 등은 .dockerignore로도 빠지지만 여기서도 굳이 안 읽는다)
  app_build_relevant_files = var.build_images ? sort(concat(
    tolist(fileset(var.app_source_path, "pyproject.toml")),
    tolist(fileset(var.app_source_path, "uv.lock")),
    tolist(fileset(var.app_source_path, "alembic.ini")),
    tolist(fileset(var.app_source_path, "dockerfile.backend")),
    tolist(fileset(var.app_source_path, "dockerfile.crawler")),
    tolist(fileset(var.app_source_path, "alembic/**")),
    tolist(fileset(var.app_source_path, "app/**")),
    tolist(fileset(var.app_source_path, "web/**")),
  )) : []

  # 소스 내용이 안 바뀌면 해시도 안 바뀌고, null_resource도 재실행되지 않는다
  # (= 인프라만 바뀐 apply에서는 재빌드/재푸시가 일어나지 않는다).
  app_source_hash = var.build_images ? sha1(join("", [
    for f in local.app_build_relevant_files : filesha1("${var.app_source_path}/${f}")
  ])) : "external"

  computed_image_tag = "git-${substr(local.app_source_hash, 0, 12)}"

  # image_tag를 직접 지정했으면 그 값을 그대로 쓰고, 아니면 소스 해시로 자동 계산한다.
  effective_image_tag = var.image_tag != "" ? var.image_tag : local.computed_image_tag

  ecr_registry = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
}

resource "null_resource" "ecr_login" {
  count = var.build_images ? 1 : 0

  triggers = {
    hash     = local.app_source_hash
    registry = local.ecr_registry
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      aws ecr get-login-password --region "${var.region}" \
        | docker login --username AWS --password-stdin "${local.ecr_registry}"
    EOT
  }

  depends_on = [
    aws_ecr_repository.backend,
    aws_ecr_repository.crawler,
  ]
}

resource "null_resource" "build_push_backend" {
  count = var.build_images ? 1 : 0

  triggers = {
    hash = local.app_source_hash
    repo = aws_ecr_repository.backend.repository_url
    tag  = local.effective_image_tag
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    working_dir = var.app_source_path
    command     = <<-EOT
      set -euo pipefail
      docker build --platform "${var.build_platform}" \
        -f dockerfile.backend \
        -t "${aws_ecr_repository.backend.repository_url}:${local.effective_image_tag}" \
        .
      docker push "${aws_ecr_repository.backend.repository_url}:${local.effective_image_tag}"
    EOT
  }

  depends_on = [null_resource.ecr_login]
}

resource "null_resource" "build_push_crawler" {
  count = var.build_images ? 1 : 0

  triggers = {
    hash = local.app_source_hash
    repo = aws_ecr_repository.crawler.repository_url
    tag  = local.effective_image_tag
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    working_dir = var.app_source_path
    command     = <<-EOT
      set -euo pipefail
      docker build --platform "${var.build_platform}" \
        -f dockerfile.crawler \
        -t "${aws_ecr_repository.crawler.repository_url}:${local.effective_image_tag}" \
        .
      docker push "${aws_ecr_repository.crawler.repository_url}:${local.effective_image_tag}"
    EOT
  }

  depends_on = [null_resource.ecr_login]
}
