resource "random_password" "db" {
  length  = 32
  special = false
}

resource "random_password" "session" {
  length  = 64
  special = false
}

resource "random_password" "admin" {
  length  = 24
  special = false
}

resource "random_password" "client" {
  length  = 24
  special = false
}

resource "random_password" "grafana" {
  length  = 24
  special = false
}

resource "aws_security_group" "rds" {
  name        = "${var.name}-rds"
  description = "Reverdi RDS - EKS nodes only"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "PostgreSQL from EKS nodes"
    protocol        = "tcp"
    from_port       = 5432
    to_port         = 5432
    # 🔴 두 보안그룹을 모두 허용한다 (2026-09-19)
    #    EKS 모듈의 node_security_group 과, EKS 가 자동 생성해
    #    노드에 실제로 붙는 cluster_primary_security_group 이 다르다.
    #    후자만 붙어 있어 마이그레이션 Job 이 TimeoutError 로 죽었다.
    security_groups = [
      module.eks.node_security_group_id,
      module.eks.cluster_primary_security_group_id,
    ]
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.tags
}

resource "aws_db_subnet_group" "rds" {
  name       = "${var.name}-rds"
  subnet_ids = module.vpc.private_subnets

  tags = var.tags
}

resource "aws_db_parameter_group" "rds" {
  name        = "${var.name}-postgres17"
  family      = "postgres17"
  description = "Reverdi PostgreSQL 17 - force TLS"

  parameter {
    name  = "rds.force_ssl"
    value = "1"

    # 🔴 pending-reboot 을 명시한다 (2026-09-19)
    #
    #    rds.force_ssl 은 정적 파라미터다. 빼놓으면 Terraform 이
    #    기본값 immediate 를 보내는데, AWS 는 pending-reboot 으로 저장한다.
    #    그러면 plan 때마다 "다르다"고 나오고, 파라미터 그룹이 바뀌면서
    #    읽기 복제본이 교체 대상이 된다 → 삭제 → 재생성 실패 → 반복.
    #
    #    오늘 이 순환에 1시간 넘게 갇혔다.
    apply_method = "pending-reboot"
  }

  tags = var.tags
}

resource "aws_db_instance" "writer" {
  identifier = "${var.name}-db"

  engine         = "postgres"
  engine_version = "17"
  instance_class = var.db_instance_class

  allocated_storage = var.db_allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true

  multi_az = true

  db_name  = "reverdi"
  username = "reverdi"
  password = random_password.db.result

  db_subnet_group_name   = aws_db_subnet_group.rds.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name    = aws_db_parameter_group.rds.name

  publicly_accessible = false

  backup_retention_period = 7
  auto_minor_version_upgrade = true

  deletion_protection = false
  skip_final_snapshot = true

  apply_immediately = false

  tags = var.tags

  depends_on = [module.eks]
}

# 🔴 임시로 껐다 (2026-09-19)
#    복제본 생성이 주 DB 백업을 유발하고, 그 백업 중에는
#    복제본을 못 만들어 실패가 반복됐다.
#    나머지를 끝낸 뒤 count = 0 줄을 지워 되살린다.
# 🔴 count 로 켜고 끈다 (2026-09-19)
#    복제본 생성이 주 DB 백업을 유발하고, 그 백업 중에는
#    복제본을 못 만들어 실패가 반복됐다.
#    문제가 생기면 0 으로 내려 나머지를 먼저 돌릴 수 있다.
resource "aws_db_instance" "reader" {
  count = var.enable_read_replica ? 1 : 0


  identifier = "${var.name}-db-ro"

  engine         = "postgres"
  instance_class = var.db_instance_class

  replicate_source_db = aws_db_instance.writer.identifier

  # 🔴 주 DB 에서 물려받는 값을 명시한다 (2026-09-19)
  #
  #    안 적으면 Terraform 이 "해제하라"(-> null)로 읽고,
  #    암호화 변경은 교체가 필요하므로 복제본을 지웠다 다시 만든다.
  #      storage_encrypted = true -> null # forces replacement
  #
  #    복제본은 주 DB 의 암호화 설정을 그대로 따르므로 값만 맞춰주면 된다.
  storage_encrypted = true

  # 🔴 파라미터 그룹을 복제본에도 붙인다 (2026-09-16 누락 발견)
  #
  #    이게 없으면 복제본은 기본 파라미터 그룹을 쓴다.
  #    → rds.force_ssl 이 적용되지 않아 평문 접속이 허용된다.
  #
  #    앱은 조회를 복제본으로 보낸다(DATABASE_RO_URL).
  #    즉 트래픽의 대부분이 암호화 강제를 안 받는 셈이었다.
  parameter_group_name = aws_db_parameter_group.rds.name

  # 🔴 보안그룹도 명시한다.
  #    안 적으면 기본 보안그룹이 붙어 노드에서 접근이 막힐 수 있다.
  vpc_security_group_ids = [aws_security_group.rds.id]

  publicly_accessible = false
  auto_minor_version_upgrade = true

  # 🔴 AZ 는 지정하지 않는다.
  #
  #    writer 가 multi_az = true 라 AWS 가 주/스탠바이 AZ 를 고른다.
  #    그 값을 apply 전에 알 수 없으므로 복제본 AZ 를 고정하면
  #    주 DB 와 같은 AZ 에 놓일 수 있다.
  #
  #    지정하지 않으면 AWS 가 서브넷 그룹 안에서 분산한다.

  deletion_protection = false
  skip_final_snapshot = true

  tags = var.tags
}
