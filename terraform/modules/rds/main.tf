# DB Subnet Group
resource "aws_db_subnet_group" "main" {
  name_prefix = "${var.name_prefix}-"
  subnet_ids  = var.subnet_ids

  tags = {
    Name = "${var.name_prefix}-db-subnet-group"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Parameter group with logical replication enabled
resource "aws_db_parameter_group" "postgres" {
  name_prefix = "${var.name_prefix}-"
  family      = "postgres16"

  parameter {
    name         = "rds.logical_replication"
    value        = "1"
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "max_replication_slots"
    value        = "5"
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "max_wal_senders"
    value        = "5"
    apply_method = "pending-reboot"
  }

  parameter {
    name  = "wal_sender_timeout"
    value = "0"
  }

  tags = {
    Name = "${var.name_prefix}-pg-params"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# RDS Postgres instance
resource "aws_db_instance" "postgres" {
  identifier_prefix = "${var.name_prefix}-"

  engine         = "postgres"
  engine_version = "16"
  instance_class = var.instance_class

  allocated_storage = var.allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true

  db_name                     = "cdc_demo"
  username                    = "postgres"
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = var.security_group_ids
  parameter_group_name   = aws_db_parameter_group.postgres.name

  auto_minor_version_upgrade = true
  backup_retention_period    = 1
  backup_window              = "03:00-04:00"
  maintenance_window         = "mon:04:00-mon:05:00"

  skip_final_snapshot      = true
  deletion_protection      = false
  delete_automated_backups = true

  enabled_cloudwatch_logs_exports = ["postgresql"]

  tags = {
    Name = "${var.name_prefix}-postgres"
  }
}
