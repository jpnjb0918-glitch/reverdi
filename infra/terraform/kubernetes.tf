# ---------------------------------------------------------------------------
# 🔴 exec 인증을 쓴다 (2026-09-16 수정)
#
#    전에는 data.aws_eks_cluster_auth 의 token 을 썼다.
#    그 토큰은 15분 만에 만료된다.
#
#    이 프로젝트의 apply 는 1.5시간이 걸린다.
#      VPC·EKS 20분 → RDS 20분 → 이미지 빌드 20~35분 → Helm 15분
#
#    토큰을 apply 시작 시점에 한 번 받으면, 뒤쪽 helm_release 차례에는
#    이미 만료돼 있다:
#      Error: Unauthorized
#      Error: the server has asked for the client to provide credentials
#
#    exec 는 필요할 때마다 aws CLI 로 새 토큰을 받는다.
#
#    ⚠️ aws CLI 가 PATH 에 있어야 한다.
#       docker-build.tf 가 ECR 로그인에 이미 쓰므로 어차피 필요하다.
# ---------------------------------------------------------------------------
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
  }
}

provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    # 위와 같은 이유로 exec 를 쓴다
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
    }
  }
}

resource "kubernetes_namespace_v1" "reverdi" {
  metadata {
    name = "reverdi"
  }

  depends_on = [module.eks]
}

resource "kubernetes_namespace_v1" "infra" {
  metadata {
    name = "infra"
  }

  depends_on = [module.eks]
}

resource "kubernetes_namespace_v1" "argocd" {
  metadata {
    name = "argocd"
  }

  depends_on = [module.eks]
}

resource "kubernetes_namespace_v1" "monitoring" {
  metadata {
    name = "monitoring"
  }

  depends_on = [module.eks]
}

resource "kubernetes_service_account_v1" "alb" {
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"

    annotations = {
      "eks.amazonaws.com/role-arn" = module.alb_controller_irsa.arn
    }
  }

  depends_on = [module.eks]
}

resource "kubernetes_service_account_v1" "web" {
  metadata {
    name      = "reverdi-web"
    namespace = kubernetes_namespace_v1.reverdi.metadata[0].name

    annotations = {
      "eks.amazonaws.com/role-arn" = module.web_irsa.arn
    }
  }
}

resource "kubernetes_service_account_v1" "batch" {
  metadata {
    name      = "reverdi-batch"
    namespace = kubernetes_namespace_v1.reverdi.metadata[0].name

    annotations = {
      "eks.amazonaws.com/role-arn" = module.batch_irsa.arn
    }
  }
}

resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"

    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type      = "gp3"
    encrypted = "true"
  }

  depends_on = [module.eks]
}

resource "kubernetes_secret_v1" "app" {
  metadata {
    name      = "reverdi-secret"
    namespace = kubernetes_namespace_v1.reverdi.metadata[0].name
  }

  type = "Opaque"


  data        = {
    DATABASE_URL    = "postgresql+asyncpg://reverdi:${random_password.db.result}@${aws_db_instance.writer.address}:5432/reverdi"
    DATABASE_RO_URL = "postgresql+asyncpg://reverdi:${random_password.db.result}@${aws_db_instance.reader.address}:5432/reverdi"
    SESSION_SECRET  = random_password.session.result
    ADMIN_USERNAME  = "admin"
    ADMIN_PASSWORD  = random_password.admin.result
    CLIENT_USERNAME = "client"
    CLIENT_PASSWORD = random_password.client.result
  }

  depends_on = [aws_db_instance.writer, aws_db_instance.reader]
}

resource "kubernetes_secret_v1" "db" {
  metadata {
    name      = "reverdi-db-secret"
    namespace = kubernetes_namespace_v1.reverdi.metadata[0].name
  }

  type = "Opaque"


  data        = {
    DATABASE_URL    = "postgresql+asyncpg://reverdi:${random_password.db.result}@${aws_db_instance.writer.address}:5432/reverdi"
    DATABASE_RO_URL = "postgresql+asyncpg://reverdi:${random_password.db.result}@${aws_db_instance.reader.address}:5432/reverdi"
  }

  depends_on = [aws_db_instance.writer, aws_db_instance.reader]
}

resource "helm_release" "alb_controller" {
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"

  wait    = true
  timeout = 900

  set = [
    {
      name  = "clusterName"
      value = module.eks.cluster_name
    },
    {
      name  = "region"
      value = var.region
    },
    {
      name  = "vpcId"
      value = module.vpc.vpc_id
    },
    {
      name  = "serviceAccount.create"
      value = "false"
    },
    {
      name  = "serviceAccount.name"
      value = "aws-load-balancer-controller"
    }
  ]

  depends_on = [
    kubernetes_service_account_v1.alb,
    module.eks
  ]
}

resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  namespace  = "kube-system"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"

  wait    = true
  timeout = 600

  depends_on = [module.eks]
}

locals {
  app_values = templatefile("${path.module}/app-values.yaml.tftpl", {
    backend_repository = aws_ecr_repository.backend.repository_url
    crawler_repository = aws_ecr_repository.crawler.repository_url

    image_tag          = local.effective_image_tag

    bucket             = aws_s3_bucket.uploads.bucket
    region              = var.region
    # 🔴 dns.tf 가 발급한 인증서를 직접 참조한다.
    #    ARN 을 손으로 복사해 넣는 단계가 없다.
    domain             = var.domain_name
    certificate_arn    = local.dns_enabled ? aws_acm_certificate_validation.alb[0].certificate_arn : ""
    cookie_secure      = local.dns_enabled
    https_enabled      = local.dns_enabled
  })
}

resource "helm_release" "app" {
  count = var.deploy_app ? 1 : 0

  name      = "reverdi"
  namespace = "reverdi"

  chart = "${path.module}/../../charts/reverdi"

  values = [local.app_values]

  wait    = true
  timeout = 1200
  atomic  = true

  depends_on = [
    helm_release.alb_controller,
    helm_release.metrics_server,
    kubernetes_secret_v1.app,
    kubernetes_secret_v1.db,
    kubernetes_service_account_v1.web,
    kubernetes_service_account_v1.batch,

    kubernetes_storage_class_v1.gp3,
    null_resource.build_push_backend,
    null_resource.build_push_crawler,

  ]

  lifecycle {
    precondition {

      condition     = local.effective_image_tag != "" && (var.build_images || var.image_tag != "")
      error_message = "deploy_app=true인데 사용할 이미지 태그를 알 수 없다. build_images=true(기본값)로 두거나, build_images=false라면 image_tag를 직접 지정하고 그 태그가 두 ECR repository에 이미 있어야 한다."

    }
  }
}

resource "helm_release" "argocd" {
  count = var.deploy_argocd ? 1 : 0

  name       = "argocd"
  namespace  = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"

  values = [
    file("${path.module}/../../helm-values/argocd.yaml"),
    file("${path.module}/../../helm-values/aws/argocd.yaml")
  ]

  wait    = true
  timeout = 900

  depends_on = [kubernetes_namespace_v1.argocd, kubernetes_storage_class_v1.gp3]
}

resource "kubernetes_secret_v1" "grafana_admin" {
  count = var.deploy_monitoring ? 1 : 0

  metadata {
    name      = "grafana-admin"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
  }

  type = "Opaque"


  data        = {

    admin-user     = "admin"
    admin-password = random_password.grafana.result
  }
}

resource "helm_release" "monitoring" {
  count = var.deploy_monitoring ? 1 : 0

  name       = "kps"
  namespace  = "monitoring"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"

  values = [
    file("${path.module}/../../helm-values/kube-prometheus-stack.yaml"),
    file("${path.module}/../../helm-values/aws/kube-prometheus-stack.yaml")
  ]

  wait    = true
  timeout = 1200

  depends_on = [
    kubernetes_namespace_v1.monitoring,
    kubernetes_secret_v1.grafana_admin,
    kubernetes_storage_class_v1.gp3
  ]
}

resource "helm_release" "jenkins" {
  count = var.deploy_jenkins ? 1 : 0

  name       = "jenkins"
  namespace  = "infra"
  repository = "https://charts.jenkins.io"
  chart      = "jenkins"

  values = [
    file("${path.module}/../../helm-values/jenkins.yaml"),
    file("${path.module}/../../helm-values/aws/jenkins.yaml")
  ]

  wait    = true
  timeout = 1200

  depends_on = [
    kubernetes_namespace_v1.infra,
    kubernetes_storage_class_v1.gp3,
    # 🔴 빌드 에이전트가 쓸 SA 가 먼저 있어야 한다.
    #    없으면 첫 빌드에서 "serviceaccount not found" 로 파드가 안 뜬다.
    kubernetes_service_account_v1.jenkins_ecr,
  ]
}
