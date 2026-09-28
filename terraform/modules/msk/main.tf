# CloudWatch Log Group for MSK broker logs
resource "aws_cloudwatch_log_group" "msk" {
  name_prefix       = "/aws/msk/${var.name_prefix}-"
  retention_in_days = 7

  tags = {
    Name = "${var.name_prefix}-msk-logs"
  }
}

# MSK Configuration
resource "aws_msk_configuration" "main" {
  name              = "${var.name_prefix}-config-${var.random_suffix}"
  kafka_versions    = ["3.5.1"]
  server_properties = <<PROPERTIES
auto.create.topics.enable=true
default.replication.factor=2
min.insync.replicas=1
num.io.threads=8
num.network.threads=5
num.replica.fetchers=2
replica.lag.time.max.ms=30000
socket.receive.buffer.bytes=102400
socket.request.max.bytes=104857600
socket.send.buffer.bytes=102400
unclean.leader.election.enable=true
zookeeper.session.timeout.ms=18000
PROPERTIES
}

# MSK Cluster (provisioned with IAM auth)
# Note: MSK Serverless does not support MSK Connect as of Dec 2024,
# so we use a provisioned cluster with the smallest viable instance type
resource "aws_msk_cluster" "main" {
  cluster_name           = "${var.name_prefix}-cluster-${var.random_suffix}"
  kafka_version          = "3.5.1"
  number_of_broker_nodes = var.broker_count

  broker_node_group_info {
    instance_type   = var.instance_type
    client_subnets  = var.subnet_ids
    security_groups = var.security_group_ids

    storage_info {
      ebs_storage_info {
        volume_size = 10
      }
    }
  }

  encryption_info {
    encryption_in_transit {
      client_broker = "TLS"
      in_cluster    = true
    }
  }

  client_authentication {
    sasl {
      iam = true
    }
  }

  configuration_info {
    arn      = aws_msk_configuration.main.arn
    revision = aws_msk_configuration.main.latest_revision
  }

  logging_info {
    broker_logs {
      cloudwatch_logs {
        enabled   = true
        log_group = aws_cloudwatch_log_group.msk.name
      }
    }
  }

  tags = {
    Name = "${var.name_prefix}-msk"
  }
}

# S3 bucket for Iceberg tables and connector plugins
resource "aws_s3_bucket" "lakehouse" {
  bucket_prefix = "${var.name_prefix}-lakehouse-"

  tags = {
    Name = "${var.name_prefix}-lakehouse"
  }
}

resource "aws_s3_bucket_versioning" "lakehouse" {
  bucket = aws_s3_bucket.lakehouse.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "lakehouse" {
  bucket = aws_s3_bucket.lakehouse.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "lakehouse" {
  bucket = aws_s3_bucket.lakehouse.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Create directories for Iceberg tables and connector plugins
resource "aws_s3_object" "iceberg_prefix" {
  bucket  = aws_s3_bucket.lakehouse.id
  key     = "iceberg/"
  content = ""
}

resource "aws_s3_object" "plugins_prefix" {
  bucket  = aws_s3_bucket.lakehouse.id
  key     = "plugins/"
  content = ""
}
