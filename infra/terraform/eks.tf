module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.19.0"

  name               = var.name
  kubernetes_version = var.kubernetes_version

  endpoint_public_access  = true
  endpoint_private_access = true

  enable_cluster_creator_admin_permissions = true
  enable_irsa                              = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets


  enabled_log_types                      = ["api", "audit", "authenticator"]
  create_cloudwatch_log_group             = true
  cloudwatch_log_group_retention_in_days  = 7

  addons = {

    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true

      # 🔴 노드보다 먼저 설치한다 (2026-09-19)
      #
      #    없으면 이 순서가 된다:
      #      노드 생성 → CNI 없음 → NotReady → 노드그룹이 Ready 를 기다림 → 교착
      #    실제로 39분간 NotReady 였고 애드온이 하나도 안 만들어졌다.
      #    eksctl 은 알아서 처리했지만 Terraform 은 명시해야 한다.
      before_compute = true

      # 🔴 이미 있는 쿠버네티스 리소스를 덮어쓴다
      #    손으로 먼저 설치한 것을 Terraform 에 넘길 때
      #    라벨이 달라 ConfigurationConflict → CREATE_FAILED 가 된다.
      #    손으로 쓴 --resolve-conflicts OVERWRITE 와 같은 뜻이다.
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
    }
  }

  eks_managed_node_groups = {
    web = {
      name           = "${var.name}-web"
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = [var.web_instance_type]
      capacity_type  = "ON_DEMAND"

      min_size     = 3
      max_size     = 6
      desired_size = 3

      use_custom_launch_template = false
      disk_size                  = 30

      labels = {
        workload = "web"
      }
    }

    batch = {
      name           = "${var.name}-batch"
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = [var.batch_instance_type]
      capacity_type  = "ON_DEMAND"

      min_size     = 1
      max_size     = 3
      desired_size = 2   #크롤러+젠킨스 나눔

      use_custom_launch_template = false
      disk_size                  = 60

      labels = {
        workload = "batch"
      }

      taints = {
        workload = {
          key    = "workload"
          value  = "batch"
          effect = "NO_SCHEDULE"
        }
      }
    }

    infra = {
      name           = "${var.name}-infra"
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = [var.infra_instance_type]
      capacity_type  = "ON_DEMAND"

      min_size     = 1
      max_size     = 3
      desired_size = var.infra_node_count

      use_custom_launch_template = false
      disk_size                  = 50

      labels = {
        workload = "infra"
      }

      taints = {
        workload = {
          key    = "workload"
          value  = "infra"
          effect = "NO_SCHEDULE"
        }
      }
    }
  }

  tags = var.tags

  # depends_on 은 쓰지 않는다.
  #   module 에 depends_on 을 붙이면 그 모듈의 모든 속성이
  #   'apply 전까지 알 수 없음' 이 되어, 안쪽 노드그룹 서브모듈의
  #   count 를 계산하지 못한다.
  #     Error: Invalid count argument
  #
  #   vpc_id / subnet_ids 로 이미 module.vpc 를 참조하므로
  #   Terraform 이 알아서 VPC 를 먼저 만든다.
}
