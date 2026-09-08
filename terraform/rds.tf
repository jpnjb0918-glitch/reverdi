resource "random_password" "db" {
  length  = 32
  special = false
}

resource "random_password" "session" {
  length  64
  special = false
}

resource "random_password" "admin" {
  length  24
  special = false
}

resource "random_password" "client" {
  length  24
  special = false
}

resource "random_password" "grafana" {
  length  24
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
    security_groups = [module.eks.node_security_group_id]
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

resource "aws_db_instance" "reader" {
  identifier = "${var.name}-db-ro"

  engine         = "postgres"
  instance_class = var.db_instance_class

  replicate_source_db = aws_db_instance.writer.identifier

  publicly_accessible = false
  auto_minor_version_upgrade = true

  deletion_protection = false
  skip_final_snapshot = true

  tags = var.tags
}
