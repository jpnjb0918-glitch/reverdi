# ---------------------------------------------------------------------------
# external-dns.tf — Ingress/Service 를 보고 Route 53 레코드를 자동 생성
#
# 🔴 왜 필요한가
#
#    ALB 와 NLB 는 Helm 이 Ingress·Service 를 만들 때
#    AWS Load Balancer Controller 가 생성한다.
#    Terraform 은 apply 시점에 그 주소를 알 수 없다.
#
#      terraform apply → ALB 주소 확인 → 콘솔에서 A 레코드 생성
#
#    이 수동 단계를 없앤다. external-dns 가 클러스터를 지켜보다가
#    Ingress 에 호스트가 적히면 Route 53 에 별칭 레코드를 만든다.
#
# 🔴 어떻게 쓰나
#
#    Ingress 나 Service 에 어노테이션을 하나 붙이면 끝이다.
#      external-dns.alpha.kubernetes.io/hostname: grafana.re-verdi.com
#
#    Ingress 는 spec.rules[].host 만 적어도 된다.
#
# 🔴 권한을 좁게 준다
#    이 호스팅 영역 하나만 바꿀 수 있다. 다른 도메인은 못 건드린다.
# ---------------------------------------------------------------------------

resource "aws_iam_policy" "external_dns" {
  count = local.dns_enabled && var.enable_external_dns ? 1 : 0

  name        = "${var.name}-external-dns"
  description = "external-dns - manage records in one hosted zone only"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["route53:ChangeResourceRecordSets"]
        # 🔴 우리 영역만. 계정의 다른 도메인은 못 만진다.
        Resource = "arn:aws:route53:::hostedzone/${data.aws_route53_zone.main[0].zone_id}"
      },
      {
        Effect   = "Allow"
        Action   = ["route53:ListHostedZones", "route53:ListResourceRecordSets", "route53:ListTagsForResource"]
        Resource = "*"
      },
    ]
  })

  tags = var.tags
}

module "external_dns_irsa" {
  count = local.dns_enabled && var.enable_external_dns ? 1 : 0

  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.8.0"

  name = "${var.name}-external-dns"

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:external-dns"]
    }
  }

  policies = {
    route53 = aws_iam_policy.external_dns[0].arn
  }

  tags = var.tags
}

resource "helm_release" "external_dns" {
  count = local.dns_enabled && var.enable_external_dns ? 1 : 0

  name       = "external-dns"
  namespace  = "kube-system"
  repository = "https://kubernetes-sigs.github.io/external-dns"
  chart      = "external-dns"
  version    = var.external_dns_chart_version

  timeout = 300
  wait    = true

  values = [yamlencode({
    provider = { name = "aws" }

    # 🔴 이 도메인만 관리한다.
    #    빼면 계정의 모든 영역을 뒤져 느려지고 위험하다.
    domainFilters = [var.domain_name]

    # 🔴 sync — 지워진 Ingress 의 레코드도 정리한다.
    #    upsert-only 면 레코드가 남아 나중에 헷갈린다.
    policy = "sync"

    # 어떤 리소스를 볼지
    sources = ["ingress", "service"]

    # 소유권 표시 — 다른 도구가 만든 레코드는 안 건드린다
    txtOwnerId = var.name

    serviceAccount = {
      create = true
      name   = "external-dns"
      annotations = {
        "eks.amazonaws.com/role-arn" = module.external_dns_irsa[0].arn
      }
    }

    resources = {
      requests = { cpu = "50m", memory = "64Mi" }
      limits   = { cpu = "200m", memory = "128Mi" }
    }
  })]

  depends_on = [
    module.eks,
    helm_release.alb_controller,
  ]
}
