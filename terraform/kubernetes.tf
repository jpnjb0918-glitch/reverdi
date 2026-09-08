provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token
}

data "aws_eks_cluster_auth" "this" {
  name = module.eks.cluster_name
}

provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.this.token
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

  string_data = {
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

  string_data = {
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
    image_tag          = var.image_tag
    bucket             = aws_s3_bucket.uploads.bucket
    region              = var.region
    domain             = var.domain
    certificate_arn    = var.acm_certificate_arn
    cookie_secure      = var.acm_certificate_arn != ""
    https_enabled      = var.acm_certificate_arn != "" && var.domain != ""
  })
}

resource "helm_release" "app" {
  count = var.deploy_app ? 1 : 0

  name      = "reverdi"
  namespace = "reverdi"

  chart = "${path.module}/../charts/reverdi"

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
    kubernetes_storage_class_v1.gp3
  ]

  lifecycle {
    precondition {
      condition     = var.image_tag != ""
      error_message = "deploy_app=true requires image_tag, and the same tag must already exist in both ECR repositories."
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
    file("${path.module}/../helm-values/argocd.yaml"),
    file("${path.module}/../helm-values/aws/argocd.yaml")
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

  string_data = {
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
    file("${path.module}/../helm-values/kube-prometheus-stack.yaml"),
    file("${path.module}/../helm-values/aws/kube-prometheus-stack.yaml")
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
    file("${path.module}/../helm-values/jenkins.yaml"),
    file("${path.module}/../helm-values/aws/jenkins.yaml")
  ]

  wait    = true
  timeout = 1200

  depends_on = [
    kubernetes_namespace_v1.infra,
    kubernetes_storage_class_v1.gp3
  ]
}
