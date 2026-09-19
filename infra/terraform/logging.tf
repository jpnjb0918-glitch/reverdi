# ---------------------------------------------------------------------------
# logging.tf — Loki + Promtail
#
# 🔴 왜 S3 에 저장하나
#
#    PVC(gp3) 에 두면
#      · 노드가 죽으면 볼륨이 다른 AZ 로 못 따라간다
#      · 20GB 를 잡아두고 실제로는 3GB 만 써도 20GB 요금
#      · 클러스터를 지우면 로그도 사라진다
#
#    S3 는
#      · 쓴 만큼만 낸다 (GB 당 월 $0.023)
#      · 클러스터를 지워도 남는다 — 사후 분석 가능
#      · IRSA 로 붙어 액세스 키가 없다
#
#    30일치 로그가 5GB 면 월 $0.12 다. PVC 20GB($1.6)보다 싸다.
#
# 🔴 구조
#
#    Promtail (DaemonSet · 모든 노드)  →  Loki (infra 노드)  →  S3
#         /var/log/pods 수집               인덱스·청크 관리      저장
#                                              ↑
#                                          Grafana 조회
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 로그 저장 버킷
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "loki" {
  count = var.enable_logging ? 1 : 0

  bucket = "${var.name}-loki-${data.aws_caller_identity.current.account_id}"

  # 시연 환경이라 지울 때 안에 든 것까지 지운다.
  # 운영이면 false 로 두고 수동 확인을 거친다.
  force_destroy = true

  tags = var.tags
}

resource "aws_s3_bucket_public_access_block" "loki" {
  count = var.enable_logging ? 1 : 0

  bucket = aws_s3_bucket.loki[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "loki" {
  count = var.enable_logging ? 1 : 0

  bucket = aws_s3_bucket.loki[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# 🔴 보존 기간 — 안 정하면 계속 쌓여 비용이 는다
resource "aws_s3_bucket_lifecycle_configuration" "loki" {
  count = var.enable_logging ? 1 : 0

  bucket = aws_s3_bucket.loki[0].id

  rule {
    id     = "expire-old-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = var.log_retention_days
    }

    # 업로드하다 만 조각도 정리한다
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# ---------------------------------------------------------------------------
# IRSA — Loki 가 S3 에 붙는다
#
# 🔴 액세스 키를 컨테이너에 넣지 않는다.
#    파드가 IAM 역할을 맡아 임시 자격증명을 받는다.
# ---------------------------------------------------------------------------
resource "aws_iam_policy" "loki_s3" {
  count = var.enable_logging ? 1 : 0

  name        = "${var.name}-loki-s3"
  description = "Loki - read/write own bucket only"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = aws_s3_bucket.loki[0].arn
      },
      {
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        # 🔴 이 버킷 안만. 다른 버킷은 못 건드린다.
        Resource = "${aws_s3_bucket.loki[0].arn}/*"
      },
    ]
  })

  tags = var.tags
}

module "loki_irsa" {
  count = var.enable_logging ? 1 : 0

  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.8.0"

  name = "${var.name}-loki"

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["monitoring:loki"]
    }
  }

  policies = {
    s3 = aws_iam_policy.loki_s3[0].arn
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Loki — SingleBinary 모드
#
# 🔴 왜 SingleBinary 인가
#    Loki 는 마이크로서비스로 쪼갤 수 있다 (읽기·쓰기·백엔드 분리).
#    대규모에서는 그게 맞지만, 파드가 6개 이상 늘어난다.
#    이 규모에서는 SingleBinary 하나로 충분하다.
# ---------------------------------------------------------------------------
resource "helm_release" "loki" {
  count = var.enable_logging ? 1 : 0

  name       = "loki"
  namespace  = "monitoring"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki"
  version    = var.loki_chart_version

  timeout = 600
  wait    = true

  values = [yamlencode({
    deploymentMode = "SingleBinary"

    loki = {
      auth_enabled = false # 단일 테넌트

      commonConfig = {
        replication_factor = 1
      }

      # 🔴 S3 저장
      storage = {
        type = "s3"
        bucketNames = {
          chunks = aws_s3_bucket.loki[0].id
          ruler  = aws_s3_bucket.loki[0].id
          admin  = aws_s3_bucket.loki[0].id
        }
        s3 = {
          region = var.region
          # 액세스 키를 적지 않는다 — IRSA 가 처리한다
        }
      }

      schemaConfig = {
        configs = [{
          from         = "2024-04-01"
          store        = "tsdb"
          object_store = "s3"
          schema       = "v13"
          index = {
            prefix = "index_"
            period = "24h"
          }
        }]
      }

      limits_config = {
        retention_period = "${var.log_retention_days * 24}h"
        # 부하 시연 때 로그가 몰려도 버티게
        ingestion_rate_mb       = 10
        ingestion_burst_size_mb = 20
      }

      compactor = {
        retention_enabled     = true
        delete_request_store  = "s3"
      }
    }

    serviceAccount = {
      create = true
      name   = "loki"
      annotations = {
        "eks.amazonaws.com/role-arn" = module.loki_irsa[0].arn
      }
    }

    singleBinary = {
      replicas = 1

      # infra 노드에만
      nodeSelector = { workload = "infra" }
      tolerations = [{
        key      = "workload"
        operator = "Equal"
        value    = "infra"
        effect   = "NoSchedule"
      }]

      resources = {
        requests = { cpu = "200m", memory = "512Mi" }
        limits   = { cpu = "1", memory = "1Gi" }
      }

      # S3 에 저장하므로 PVC 는 작게 — WAL 과 캐시만
      persistence = {
        enabled      = true
        storageClass = "gp3"
        size         = "10Gi"
      }
    }

    # SingleBinary 에서는 아래 컴포넌트를 쓰지 않는다
    read        = { replicas = 0 }
    write       = { replicas = 0 }
    backend     = { replicas = 0 }
    chunksCache = { enabled = false }
    resultsCache = { enabled = false }

    # 게이트웨이(nginx)도 불필요 — Grafana 가 직접 붙는다
    gateway = { enabled = false }

    test        = { enabled = false }
    lokiCanary  = { enabled = false }
  })]

  depends_on = [
    module.eks,
    kubernetes_namespace_v1.monitoring,
    kubernetes_storage_class_v1.gp3,
    aws_s3_bucket_lifecycle_configuration.loki,
  ]
}

# ---------------------------------------------------------------------------
# Promtail — 로그 수집기
#
# 🔴 DaemonSet 이라 모든 노드에 하나씩 뜬다.
#    taint 가 걸린 batch·infra 노드에도 떠야 하므로
#    tolerations.operator = Exists 로 전부 허용한다.
#
# 🔴 팀원이 보낸 설정에서 뺀 것
#      hostPath: /home/vagrant/logs   ← Vagrant 경로. EKS 노드에 없다.
#    SonarQube 는 컨테이너라 /var/log/pods 로 이미 수집된다.
# ---------------------------------------------------------------------------
resource "helm_release" "promtail" {
  count = var.enable_logging ? 1 : 0

  name       = "promtail"
  namespace  = "monitoring"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "promtail"
  version    = var.promtail_chart_version

  timeout = 300
  wait    = true

  values = [yamlencode({
    config = {
      clients = [{
        url = "http://loki:3100/loki/api/v1/push"
      }]
    }

    # 🔴 모든 노드에 뜬다 — taint 를 전부 허용
    tolerations = [
      { effect = "NoSchedule", operator = "Exists" },
      { effect = "NoExecute", operator = "Exists" },
    ]

    resources = {
      requests = { cpu = "50m", memory = "64Mi" }
      limits   = { cpu = "200m", memory = "128Mi" }
    }
  })]

  depends_on = [helm_release.loki]
}

# ---------------------------------------------------------------------------
# ⚠️ Grafana 에 Loki 데이터소스 추가
#
#    kube-prometheus-stack 의 Grafana 가 Loki 를 보게 하려면
#    helm-values/aws/kube-prometheus-stack.yaml 에 추가한다:
#
#      grafana:
#        additionalDataSources:
#          - name: Loki
#            type: loki
#            access: proxy
#            url: http://loki.monitoring.svc.cluster.local:3100
#
#    🔴 이걸 안 하면 대시보드가 데이터소스를 못 찾는다.
# ---------------------------------------------------------------------------
