# ---------------------------------------------------------------------------
# sonarqube.tf
#
# 정적 분석 서버. Jenkins 파이프라인의 sonarqube 단계가 여기로 결과를 보낸다.
#
# 🔴 왜 infra 노드를 키웠나
#    SonarQube 는 JVM 과 Elasticsearch 를 함께 돌려 메모리를 많이 쓴다.
#      sonarqube   2.0GB
#      postgresql  0.3GB
#    infra 노드에 이미 argocd · prometheus · grafana · jenkins 가 있어
#    t3.medium(할당 가능 3.3GB) 으로는 들어가지 않는다.
#    variables.tf 에서 t3.large × 2 로 바꿨다.
#
# 🔴 왜 내장 PostgreSQL 을 쓰나
#    앱이 쓰는 RDS 와 섞지 않는다. SonarQube 가 DB 를 망가뜨려도
#    서비스 데이터에 영향이 없어야 한다.
#    분석 결과는 날아가도 다시 스캔하면 되므로 내장으로 충분하다.
#
# 🔴 인터넷에 노출하지 않는다
#    ClusterIP 로 둔다. Jenkins 는 클러스터 안에서 부르고,
#    사람이 볼 때는 포트포워딩한다.
#      kubectl port-forward -n infra svc/sonarqube-sonarqube 9000:9000
# ---------------------------------------------------------------------------

resource "random_password" "sonarqube_admin" {
  count = var.enable_sonarqube && var.sonarqube_admin_password == "" ? 1 : 0

  length  = 20
  special = false
}

locals {
  sonarqube_password = var.enable_sonarqube ? (
    var.sonarqube_admin_password != ""
    ? var.sonarqube_admin_password
    : random_password.sonarqube_admin[0].result
  ) : ""

  # Jenkins 가 클러스터 안에서 부를 주소.
  # 서비스 이름은 차트가 <릴리스명>-sonarqube 로 만든다.
  sonarqube_internal_url = var.enable_sonarqube ? "http://sonarqube-sonarqube.infra.svc.cluster.local:9000" : ""
}

resource "helm_release" "sonarqube" {
  count = var.enable_sonarqube ? 1 : 0

  name       = "sonarqube"
  namespace  = "infra"
  repository = "https://SonarSource.github.io/helm-chart-sonarqube"
  chart      = "sonarqube"
  # version    = var.sonarqube_chart_version

  # 기동에 오래 걸린다. Elasticsearch 가 올라오길 기다려야 한다.
  timeout = 900
  wait    = true

  values = [yamlencode({
    # --- 배치 ---------------------------------------------------------
    # infra 노드에만 뜨게 한다. 웹 노드의 자원을 쓰면 서비스가 흔들린다.
    nodeSelector = { workload = "infra" }
    tolerations = [{
      key      = "workload"
      operator = "Equal"
      value    = "infra"
      effect   = "NoSchedule"
    }]

    # --- 노출 ---------------------------------------------------------
    # 🔴 ClusterIP. 인터넷에 열지 않는다.
    service = { type = "ClusterIP" }
    ingress = { enabled = false }

    # --- 계정 ---------------------------------------------------------
    account = {
      adminPassword        = local.sonarqube_password
      currentAdminPassword = "admin" # 차트 기본값에서 바꾼다
    }

    # --- 자원 ---------------------------------------------------------
    # requests 는 스케줄링용 최소치, limits 가 상한이다.
    # Elasticsearch 가 힙을 잡으므로 limits 를 넉넉히 준다.
    resources = {
      requests = { cpu = "500m", memory = "2Gi" }
      limits   = { cpu = "2", memory = "4Gi" }
    }

    # --- 저장소 -------------------------------------------------------
    persistence = {
      enabled          = true
      storageClass     = "gp3"
      size             = "10Gi"
      accessMode       = "ReadWriteOnce"
    }

    # --- DB -----------------------------------------------------------
    # 🔴 앱의 RDS 와 섞지 않는다. 내장 PostgreSQL 을 쓴다.
    postgresql = {
      enabled = true
      primary = {
        nodeSelector = { workload = "infra" }
        tolerations = [{
          key      = "workload"
          operator = "Equal"
          value    = "infra"
          effect   = "NoSchedule"
        }]
        persistence = {
          enabled      = true
          storageClass = "gp3"
          size         = "8Gi"
        }
        resources = {
          requests = { cpu = "100m", memory = "256Mi" }
          limits   = { cpu = "500m", memory = "512Mi" }
        }
      }
    }

    # --- 커널 파라미터 -------------------------------------------------
    # 🔴 Elasticsearch 가 vm.max_map_count 를 요구한다.
    #    EKS 의 AL2023 노드는 기본값이 낮아 initContainer 가 올려줘야 한다.
    #    이게 없으면 "max virtual memory areas is too low" 로 죽는다.
    initSysctl = {
      enabled    = true
      vmMaxMapCount = 524288
      fsFileMax     = 131072
    }

    # 모니터링 패스코드는 쓰지 않지만 차트가 요구한다
    monitoringPasscode = "reverdi-monitoring"
  })]

  depends_on = [
    module.eks,
    kubernetes_namespace_v1.infra,
    kubernetes_storage_class_v1.gp3,
  ]
}
