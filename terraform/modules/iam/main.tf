data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id

  # Extract cluster name and UUID from cluster ARN for topic/group ARNs
  # Cluster ARN format: arn:aws:kafka:region:account:cluster/name/uuid
  cluster_name_parts = split("/", var.msk_cluster_arn)
  cluster_name       = local.cluster_name_parts[1]
  cluster_uuid       = local.cluster_name_parts[2]
}

# IAM role for Debezium connector
resource "aws_iam_role" "debezium_connector" {
  name_prefix = "${var.name_prefix}-debezium-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "kafkaconnect.amazonaws.com"
      }
    }]
  })

  tags = {
    Name = "${var.name_prefix}-debezium-connector-role"
  }
}

# Debezium connector policy
resource "aws_iam_role_policy" "debezium_connector" {
  name_prefix = "debezium-policy-"
  role        = aws_iam_role.debezium_connector.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "MSKConnectAccess"
        Effect = "Allow"
        Action = [
          "kafka-cluster:Connect",
          "kafka-cluster:AlterCluster",
          "kafka-cluster:DescribeCluster",
          "kafka-cluster:WriteDataIdempotently"
        ]
        Resource = var.msk_cluster_arn
      },
      {
        Sid    = "MSKTopicAccess"
        Effect = "Allow"
        Action = [
          "kafka-cluster:CreateTopic",
          "kafka-cluster:AlterTopic",
          "kafka-cluster:DescribeTopic",
          "kafka-cluster:DescribeTopicDynamicConfiguration",
          "kafka-cluster:WriteData",
          "kafka-cluster:ReadData"
        ]
        Resource = "arn:aws:kafka:${var.region}:${local.account_id}:topic/${local.cluster_name}/${local.cluster_uuid}/*"
      },
      {
        Sid    = "MSKGroupAccess"
        Effect = "Allow"
        Action = [
          "kafka-cluster:AlterGroup",
          "kafka-cluster:DescribeGroup"
        ]
        # Include both Connect internal groups and connector-specific groups
        Resource = [
          "arn:aws:kafka:${var.region}:${local.account_id}:group/${local.cluster_name}/${local.cluster_uuid}/__amazon_msk_connect_*",
          "arn:aws:kafka:${var.region}:${local.account_id}:group/${local.cluster_name}/${local.cluster_uuid}/connect-*",
          "arn:aws:kafka:${var.region}:${local.account_id}:group/${local.cluster_name}/${local.cluster_uuid}/debezium-*"
        ]
      },
      {
        Sid    = "MSKTransactionalIdAccess"
        Effect = "Allow"
        Action = [
          "kafka-cluster:DescribeTransactionalId",
          "kafka-cluster:AlterTransactionalId"
        ]
        Resource = "arn:aws:kafka:${var.region}:${local.account_id}:transactional-id/${local.cluster_name}/${local.cluster_uuid}/*"
      },
      {
        Sid    = "S3PluginAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          var.s3_bucket_arn,
          "${var.s3_bucket_arn}/plugins/*"
        ]
      },
      {
        Sid    = "SecretsManagerAccess"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = var.rds_secret_arn
      },
      {
        Sid    = "CloudWatchLogsAccess"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.region}:${local.account_id}:log-group:/aws/msk-connect/${var.name_prefix}-debezium-*:*"
      },
      {
        Sid    = "VPCAccess"
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:CreateNetworkInterfacePermission",
          "ec2:DeleteNetworkInterface",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeVpcs"
        ]
        Resource = "*"
      }
    ]
  })
}

# IAM role for Iceberg connector
resource "aws_iam_role" "iceberg_connector" {
  name_prefix = "${var.name_prefix}-iceberg-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "kafkaconnect.amazonaws.com"
      }
    }]
  })

  tags = {
    Name = "${var.name_prefix}-iceberg-connector-role"
  }
}

# Iceberg connector policy
resource "aws_iam_role_policy" "iceberg_connector" {
  name_prefix = "iceberg-policy-"
  role        = aws_iam_role.iceberg_connector.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "MSKConnectAccess"
        Effect = "Allow"
        Action = [
          "kafka-cluster:Connect",
          "kafka-cluster:AlterCluster",
          "kafka-cluster:DescribeCluster",
          "kafka-cluster:WriteDataIdempotently"
        ]
        Resource = var.msk_cluster_arn
      },
      {
        Sid    = "MSKTopicAccess"
        Effect = "Allow"
        Action = [
          "kafka-cluster:CreateTopic",
          "kafka-cluster:AlterTopic",
          "kafka-cluster:DescribeTopic",
          "kafka-cluster:DescribeTopicDynamicConfiguration",
          "kafka-cluster:WriteData",
          "kafka-cluster:ReadData"
        ]
        Resource = "arn:aws:kafka:${var.region}:${local.account_id}:topic/${local.cluster_name}/${local.cluster_uuid}/*"
      },
      {
        Sid    = "MSKGroupAccess"
        Effect = "Allow"
        Action = [
          "kafka-cluster:AlterGroup",
          "kafka-cluster:DescribeGroup"
        ]
        # Include Connect internal groups and Iceberg-specific groups
        Resource = [
          "arn:aws:kafka:${var.region}:${local.account_id}:group/${local.cluster_name}/${local.cluster_uuid}/__amazon_msk_connect_*",
          "arn:aws:kafka:${var.region}:${local.account_id}:group/${local.cluster_name}/${local.cluster_uuid}/connect-*",
          "arn:aws:kafka:${var.region}:${local.account_id}:group/${local.cluster_name}/${local.cluster_uuid}/cg-control-*",
          "arn:aws:kafka:${var.region}:${local.account_id}:group/${local.cluster_name}/${local.cluster_uuid}/iceberg-*"
        ]
      },
      {
        Sid    = "MSKTransactionalIdAccess"
        Effect = "Allow"
        Action = [
          "kafka-cluster:DescribeTransactionalId",
          "kafka-cluster:AlterTransactionalId"
        ]
        Resource = "arn:aws:kafka:${var.region}:${local.account_id}:transactional-id/${local.cluster_name}/${local.cluster_uuid}/*"
      },
      {
        Sid    = "S3PluginAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          var.s3_bucket_arn,
          "${var.s3_bucket_arn}/plugins/*"
        ]
      },
      {
        Sid    = "S3IcebergAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          var.s3_bucket_arn,
          "${var.s3_bucket_arn}/iceberg/*"
        ]
      },
      {
        Sid    = "GlueAccess"
        Effect = "Allow"
        Action = [
          "glue:GetDatabase",
          "glue:GetTable",
          "glue:CreateTable",
          "glue:UpdateTable",
          "glue:DeleteTable",
          "glue:GetPartition",
          "glue:GetPartitions",
          "glue:CreatePartition",
          "glue:UpdatePartition",
          "glue:DeletePartition",
          "glue:BatchGetPartition",
          "glue:BatchCreatePartition",
          "glue:BatchDeletePartition",
          "glue:BatchUpdatePartition"
        ]
        Resource = [
          "arn:aws:glue:${var.region}:${local.account_id}:catalog",
          "arn:aws:glue:${var.region}:${local.account_id}:database/${var.glue_database_name}",
          "arn:aws:glue:${var.region}:${local.account_id}:table/${var.glue_database_name}/*"
        ]
      },
      {
        Sid    = "CloudWatchLogsAccess"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.region}:${local.account_id}:log-group:/aws/msk-connect/${var.name_prefix}-iceberg-*:*"
      },
      {
        Sid    = "VPCAccess"
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:CreateNetworkInterfacePermission",
          "ec2:DeleteNetworkInterface",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeVpcs"
        ]
        Resource = "*"
      }
    ]
  })
}
