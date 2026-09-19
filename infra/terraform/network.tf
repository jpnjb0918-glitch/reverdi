module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.6.1"

  name = var.name
  cidr = var.vpc_cidr

  azs             = var.azs
  public_subnets  = var.public_subnets
  private_subnets = var.private_subnets

  enable_nat_gateway = true
  single_nat_gateway = true

  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
    "kubernetes.io/cluster/${var.name}" = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
    "kubernetes.io/cluster/${var.name}" = "shared"
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# 🔴 S3 게이트웨이 엔드포인트 (2026-09-16 누락 발견)
#
#    없으면 S3 트래픽이 전부 NAT 을 탄다.
#      · 업로드 이미지 (앱 → S3)
#      · Loki 로그 청크 (계속 쌓인다)
#      · pg_dump 백업
#
#    NAT 데이터 처리 GB 당 $0.045 · 게이트웨이 엔드포인트는 요금 0.
#
#    ⚠️ VPC 모듈 v6 에는 enable_s3_endpoint 인자가 없다.
#       v5 까지는 있었는데 제거됐다. 별도 리소스로 만든다.
#
#    ⚠️ 인터페이스 엔드포인트(ECR 등)는 AZ 당 시간당 $0.01 이라
#       6종 × 3AZ 면 월 $131 이다. 이 규모에서는 NAT 이 싸다.
#       게이트웨이형(S3·DynamoDB)만 요금이 없어 그것만 쓴다.
# ---------------------------------------------------------------------------
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"

  # 사설 서브넷의 라우팅 테이블에 S3 경로를 넣는다.
  # 이게 있어야 NAT 대신 엔드포인트로 간다.
  route_table_ids = module.vpc.private_route_table_ids

  tags = merge(var.tags, { Name = "${var.name}-s3-endpoint" })
}
