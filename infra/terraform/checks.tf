# ---------------------------------------------------------------------------
# 🔴 사전 검증 (2026-09-16 추가)
#
#    app_source_path 가 틀리면 plan 은 통과하고 apply 중간에 멈춘다.
#      fileset() 은 경로가 없어도 빈 목록을 반환한다 (오류 없음)
#      → 해시가 sha1("") 이 되어 태그는 그럴듯하게 생긴다
#      → docker build 에서야 "path does not exist" 로 실패
#      → 이미 만든 VPC · EKS · RDS 는 그대로 남는다 (20~40분 낭비)
#
#    plan 단계에서 잡는다.
# ---------------------------------------------------------------------------
check "app_source_path_valid" {
  assert {
    condition = !var.build_images || length(fileset(var.app_source_path, "dockerfile.backend")) > 0
    error_message = <<-EOT
      app_source_path 에 dockerfile.backend 가 없습니다: ${var.app_source_path}

      CloudeDX 소스 루트를 가리켜야 합니다. terraform.tfvars 에서 고치세요.
        app_source_path = "D:/project/CloudeDX"

      이미 CI 에서 이미지를 올렸다면 build_images = false 로 두고
      image_tag 를 직접 지정하세요.
    EOT
  }
}
