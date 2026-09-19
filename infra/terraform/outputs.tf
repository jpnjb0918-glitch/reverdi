output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "ecr_backend_repository" {
  value = aws_ecr_repository.backend.repository_url
}

output "ecr_crawler_repository" {
  value = aws_ecr_repository.crawler.repository_url
}

output "s3_upload_bucket" {
  value = aws_s3_bucket.uploads.bucket
}

output "rds_writer_endpoint" {
  value = aws_db_instance.writer.address
}

output "rds_reader_endpoint" {
  value = aws_db_instance.reader.address
}

output "admin_username" {
  value = "admin"
}

output "admin_password" {
  value     = random_password.admin.result
  sensitive = true
}

output "client_username" {
  value = "client"
}

output "client_password" {
  value     = random_password.client.result
  sensitive = true
}

output "grafana_password" {
  value     = random_password.grafana.result
  sensitive = true
}

output "configure_kubeconfig" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "app_url" {
  value = var.domain_name != "" ? "https://${var.domain_name}" : "http://<ALB-DNS>"
}

# ---------------------------------------------------------------------------
# SonarQube
# ---------------------------------------------------------------------------
output "sonarqube_internal_url" {
  description = "Jenkins 가 클러스터 안에서 쓸 주소. 파이프라인 SONARQUBE_URL 에 넣는다."
  value       = local.sonarqube_internal_url
}

output "sonarqube_admin_password" {
  description = "SonarQube admin 비밀번호. terraform output -raw sonarqube_admin_password"
  value       = local.sonarqube_password
  sensitive   = true
}

output "sonarqube_port_forward" {
  description = "브라우저로 볼 때 쓰는 명령"
  value       = var.enable_sonarqube ? "kubectl port-forward -n infra svc/sonarqube-sonarqube 9000:9000" : "(비활성)"
}

# ===========================================================================
# 시연용 주소
# ===========================================================================

output "app_url_https" {
  value       = var.domain_name != "" ? "https://${var.domain_name}" : "(도메인 미설정 — ALB 주소 사용)"
  description = "웹 앱"
}

output "grafana_url" {
  value = var.domain_name != "" ? (
    "https://grafana.${var.domain_name}"
  ) : "kubectl port-forward -n monitoring svc/kps-grafana 3000:80"
  description = "🔴 팀원이 브라우저로 여는 주소 (AWS 자격증명 불필요)"
}

output "alb_certificate_arn" {
  value       = var.domain_name != "" ? aws_acm_certificate_validation.alb[0].certificate_arn : ""
  description = "ALB 용 ACM 인증서. 컨트롤러가 자동 매칭하므로 보통 쓸 일이 없다."
}
