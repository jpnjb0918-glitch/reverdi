# ---------------------------------------------------------------------------
# dns.tf — Route 53 + ACM 인증서
#
# 🔴 도메인 등록은 Terraform 으로 하지 않는다
#    aws_route53domains_* 는 "이미 산 도메인을 관리"하는 리소스다.
#    구매는 콘솔에서 한다 — 결제가 걸려 있어 실수로 지우면 곤란하다.
#
#      Route 53 → 등록된 도메인 → 도메인 등록
#      .com 기준 연 $14 · 등록하면 호스팅 영역이 자동 생성된다
#
#    산 뒤에 terraform.tfvars 에 도메인을 적으면 나머지가 붙는다.
#      domain_name = "reverdi.com"
#
# 🔴 인증서는 ALB 와 같은 리전(ap-northeast-2)에 있어야 한다.
#    ALB 컨트롤러가 Ingress 의 host 에 맞는 인증서를 ACM 에서 찾아 붙인다.
#    values-aws.yaml 의 certificateArn 을 비워두면 자동 매칭된다.
# ---------------------------------------------------------------------------

locals {
  # 도메인을 안 적으면 이 파일의 모든 리소스가 만들어지지 않는다.
  # 도메인 없이도 ALB 주소로 접속할 수 있게 하기 위해서다.
  dns_enabled = var.domain_name != ""
}

# 콘솔에서 도메인을 등록하면 호스팅 영역이 함께 생긴다.
# 그것을 찾아 쓴다 — 새로 만들지 않는다.
# (새로 만들면 네임서버가 달라져 도메인이 그 영역을 안 본다)
data "aws_route53_zone" "main" {
  count = local.dns_enabled ? 1 : 0

  name         = var.domain_name
  private_zone = false
}

# ---------------------------------------------------------------------------
# ALB 용 인증서 — ap-northeast-2
# ---------------------------------------------------------------------------
resource "aws_acm_certificate" "alb" {
  count = local.dns_enabled ? 1 : 0

  domain_name       = var.domain_name
  validation_method = "DNS"

  subject_alternative_names = ["*.${var.domain_name}"]

  # 인증서를 바꿀 때 새것을 먼저 만들고 옛것을 지운다.
  # 반대로 하면 그 사이 HTTPS 가 끊긴다.
  lifecycle {
    create_before_destroy = true
  }

  tags = var.tags
}

# 🔴 for_each 키를 레코드 이름으로 잡는다 (2026-09-16 수정)
#
#    인증서가 도메인 두 개를 담는다:
#      re-verdi.com  ·  *.re-verdi.com
#
#    ACM 은 둘에 대해 같은 검증 레코드를 준다 (같은 영역이므로).
#    키를 domain_name 으로 잡으면 항목이 2개가 되는데
#    실제로 만드는 레코드는 하나다 — 같은 것을 두 번 만들려 든다.
#
#    resource_record_name 을 키로 쓰면 자동으로 중복이 합쳐진다.
#    Terraform 공식 예제도 이 방식이다.
resource "aws_route53_record" "alb_cert_validation" {
  for_each = local.dns_enabled ? {
    for o in aws_acm_certificate.alb[0].domain_validation_options :
    o.resource_record_name => {
      type   = o.resource_record_type
      record = o.resource_record_value
    }
  } : {}

  zone_id = data.aws_route53_zone.main[0].zone_id
  name    = each.key
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60

  # 재실행 시 이미 있는 레코드를 덮어쓴다.
  # 검증 레코드는 언제 덮어써도 안전하다.
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "alb" {
  count = local.dns_enabled ? 1 : 0

  certificate_arn         = aws_acm_certificate.alb[0].arn
  validation_record_fqdns = [for r in aws_route53_record.alb_cert_validation : r.fqdn]

  timeouts {
    create = "10m"
  }
}

# ---------------------------------------------------------------------------
# 🔴 ALB 를 가리키는 A 레코드는 여기서 만들지 않는다
#
#   ALB 는 Helm 이 Ingress 를 만들 때 AWS Load Balancer Controller 가 생성한다.
#   Terraform 은 그 주소를 apply 시점에 알 수 없다.
#
#   대신 external-dns.tf 가 그 일을 한다.
#   클러스터 안에서 Ingress 를 지켜보다가 host 가 적히면
#   Route 53 에 별칭 레코드를 만든다.
#
#   ⚠️ Terraform 이 직접 만들려 하면 순환 의존이 생긴다.
#      레코드 → ALB 주소 → Ingress → Helm → 클러스터 → ...
#      그래서 클러스터 안에서 도는 컨트롤러에 맡긴다.
# ---------------------------------------------------------------------------
