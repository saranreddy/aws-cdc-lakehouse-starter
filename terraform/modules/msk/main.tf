# MSK Serverless cluster with IAM auth
# Note: MSK Serverless requires IAM auth (no SASL/SCRAM or mTLS)
# Topics must be explicitly created (no auto-topic-creation)
resource "aws_msk_serverless_cluster" "main" {
  cluster_name = "${var.name_prefix}-serverless-${var.random_suffix}"

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = var.security_group_ids
  }

  client_authentication {
    sasl {
      iam {
        enabled = true
      }
    }
  }

  tags = {
    Name = "${var.name_prefix}-msk-serverless"
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
