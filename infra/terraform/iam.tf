module "alb_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.8.0"

  name = "${var.name}-aws-load-balancer-controller"

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }

  attach_load_balancer_controller_policy = true
}

module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.8.0"

  name = "${var.name}-ebs-csi"

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }

  attach_ebs_csi_policy = true
}

module "web_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.8.0"

  name = "${var.name}-web"

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["reverdi:reverdi-web"]
    }
  }


  policies = {
    s3 = aws_iam_policy.web_s3.arn
  }
}

module "batch_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.8.0"

  name = "${var.name}-batch"

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["reverdi:reverdi-batch"]
    }
  }


  policies = {
    s3 = aws_iam_policy.batch_s3.arn
  }
}

resource "aws_iam_policy" "web_s3" {
  name = "${var.name}-web-s3"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.uploads.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.uploads.arn
      }
    ]
  })
}

resource "aws_iam_policy" "batch_s3" {
  name = "${var.name}-batch-s3"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.uploads.arn}/*"
      }
    ]
  })
}


resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = module.eks.cluster_name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = module.ebs_csi_irsa.arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    module.ebs_csi_irsa,
    module.eks
  ]
}

# ---------------------------------------------------------------------------
# 🔴 Jenkins 빌드 에이전트 — ECR push 권한 (2026-09-16 누락 발견)
#
#    Jenkinsfile 의 BUILD_POD 가 이 SA 를 쓴다:
#      serviceAccountName: jenkins-ecr
#
#    없으면 파드가 아예 안 뜬다:
#      serviceaccount "jenkins-ecr" not found
#
# 🔴 왜 reverdi-batch 를 못 쓰나
#    reverdi-batch 는 reverdi 네임스페이스에 있다.
#    Jenkins 빌드 파드는 infra 네임스페이스에서 뜨므로 그 SA 를 못 본다.
#    ServiceAccount 는 네임스페이스를 넘지 못한다.
#
# 🔴 권한을 좁게 준다
#    PowerUser 는 push·pull 은 되지만 저장소 삭제는 안 된다.
#    빌드에는 그걸로 충분하다.
# ---------------------------------------------------------------------------
module "jenkins_ecr_irsa" {
  count = var.deploy_jenkins ? 1 : 0

  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.8.0"

  name = "${var.name}-jenkins-ecr"

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["infra:jenkins-ecr"]
    }
  }

  policies = {
    ecr = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
  }

  tags = var.tags
}

# IRSA 모듈은 역할만 만든다. ServiceAccount 는 따로 만들어야 한다.
resource "kubernetes_service_account_v1" "jenkins_ecr" {
  count = var.deploy_jenkins ? 1 : 0

  metadata {
    name      = "jenkins-ecr"
    namespace = kubernetes_namespace_v1.infra.metadata[0].name

    annotations = {
      "eks.amazonaws.com/role-arn" = module.jenkins_ecr_irsa[0].arn
    }
  }
}
