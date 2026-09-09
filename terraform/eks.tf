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

  cluster_enabled_log_types              = ["api", "audit", "authenticator"]
  create_cloudwatch_log_group             = true
  cloudwatch_log_group_retention_in_days  = 7

  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
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
      max_size     = 1
      desired_size = 1

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

  depends_on = [module.vpc]
}
