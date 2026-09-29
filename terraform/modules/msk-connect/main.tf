# MSK Connect Connectors for CDC Pipeline
# Runtime: MSK Connect 3.7.x (Kafka 3.7.x, Java 17)
# Debezium 2.7.3.Final (Java 11+ compatible, runs on Java 17)
# Tabular Iceberg Kafka Connect 0.6.19

# Fetch and upload Debezium connector plugin
# Debezium 2.7.3.Final is compatible with Kafka Connect 2.x/3.x and Java 11+
resource "null_resource" "fetch_debezium_plugin" {
  provisioner "local-exec" {
    command = <<-EOF
      set -e
      PLUGIN_DIR="/tmp/debezium-plugin-${var.random_suffix}"
      mkdir -p "$PLUGIN_DIR"
      cd "$PLUGIN_DIR"
      
      # Download Debezium Postgres connector 2.7.3.Final
      DEBEZIUM_VERSION="2.7.3.Final"
      DEBEZIUM_URL="https://repo1.maven.org/maven2/io/debezium/debezium-connector-postgres/$DEBEZIUM_VERSION/debezium-connector-postgres-$DEBEZIUM_VERSION-plugin.tar.gz"
      EXPECTED_SHA256="9bf3f06419d30c57eb9d0d2e717f8148bcf35eb174e1dc7f1acc182da803d9f1"
      
      echo "Downloading Debezium $DEBEZIUM_VERSION..."
      curl -fsSL "$DEBEZIUM_URL" -o debezium-connector-postgres.tar.gz
      
      # Verify SHA256
      ACTUAL_SHA256=$(shasum -a 256 debezium-connector-postgres.tar.gz | cut -d' ' -f1)
      echo "Expected SHA256: $EXPECTED_SHA256"
      echo "Actual SHA256:   $ACTUAL_SHA256"
      
      if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
        echo "Error: SHA256 mismatch!"
        exit 1
      fi
      
      echo "SHA256 verified successfully"
      
      # Extract
      tar -xzf debezium-connector-postgres.tar.gz
      
      # Download AWS Secrets Manager config provider
      CONFIG_PROVIDER_VERSION="0.4.0"
      CONFIG_PROVIDER_URL="https://github.com/aws-samples/msk-config-providers/releases/download/r0.4.0/msk-config-providers-0.4.0-all.jar"
      CONFIG_PROVIDER_SHA256="45dc671c2cec8412c436371abddff644598d00035a73487ab6db191db3563911"
      
      echo "Downloading AWS Config Providers $CONFIG_PROVIDER_VERSION..."
      curl -fsSL "$CONFIG_PROVIDER_URL" -o msk-config-providers.jar
      
      # Verify SHA256
      ACTUAL_SHA256=$(shasum -a 256 msk-config-providers.jar | cut -d' ' -f1)
      echo "Expected SHA256: $CONFIG_PROVIDER_SHA256"
      echo "Actual SHA256:   $ACTUAL_SHA256"
      
      if [ "$ACTUAL_SHA256" != "$CONFIG_PROVIDER_SHA256" ]; then
        echo "Error: Config provider SHA256 mismatch!"
        exit 1
      fi
      
      echo "Config provider SHA256 verified successfully"
      
      # Add config provider to plugin
      mv msk-config-providers.jar debezium-connector-postgres/
      
      # Create zip for MSK Connect
      cd debezium-connector-postgres
      zip -r ../debezium-postgres-connector.zip .
      cd ..
      
      # Upload to S3
      aws s3 cp debezium-postgres-connector.zip "s3://${var.s3_bucket_name}/plugins/debezium-postgres-connector-$DEBEZIUM_VERSION.zip"
      
      echo "Debezium plugin uploaded to S3"
      
      # Cleanup
      rm -rf "$PLUGIN_DIR"
    EOF
  }

  triggers = {
    version = "2.7.3.Final"
    sha256  = "9bf3f06419d30c57eb9d0d2e717f8148bcf35eb174e1dc7f1acc182da803d9f1"
  }

  depends_on = [var.s3_bucket_name]
}

# Fetch and build Tabular Iceberg connector
# Tabular iceberg-kafka-connect 0.6.19 (last stable release before deprecation)
resource "null_resource" "fetch_iceberg_plugin" {
  provisioner "local-exec" {
    command = <<-EOF
      set -e
      PLUGIN_DIR="/tmp/iceberg-plugin-${var.random_suffix}"
      mkdir -p "$PLUGIN_DIR"
      cd "$PLUGIN_DIR"
      
      # Download pre-built release zip from GitHub
      ICEBERG_VERSION="0.6.19"
      ICEBERG_URL="https://github.com/tabular-io/iceberg-kafka-connect/releases/download/v$ICEBERG_VERSION/iceberg-kafka-connect-runtime-$ICEBERG_VERSION.zip"
      EXPECTED_SHA256="531f6d1b1780cc524144dc2bc8ecbb70bb9413f3a5442140e25321ff0d7de330"
      
      echo "Downloading Tabular Iceberg Kafka Connect $ICEBERG_VERSION..."
      curl -fsSL "$ICEBERG_URL" -o iceberg-kafka-connect.zip
      
      # Verify SHA256
      ACTUAL_SHA256=$(shasum -a 256 iceberg-kafka-connect.zip | cut -d' ' -f1)
      echo "Expected SHA256: $EXPECTED_SHA256"
      echo "Actual SHA256:   $ACTUAL_SHA256"
      
      if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
        echo "Error: SHA256 mismatch!"
        exit 1
      fi
      
      echo "SHA256 verified successfully"
      
      # Upload to S3
      aws s3 cp iceberg-kafka-connect.zip "s3://${var.s3_bucket_name}/plugins/iceberg-kafka-connect-$ICEBERG_VERSION.zip"
      
      echo "Iceberg plugin uploaded to S3"
      
      # Cleanup
      rm -rf "$PLUGIN_DIR"
    EOF
  }

  triggers = {
    version = "0.6.19"
    sha256  = "531f6d1b1780cc524144dc2bc8ecbb70bb9413f3a5442140e25321ff0d7de330"
  }

  depends_on = [var.s3_bucket_name]
}

# Worker configuration for Debezium with Secrets Manager config provider
resource "aws_mskconnect_worker_configuration" "debezium" {
  name = "${var.name_prefix}-debezium-worker-${var.random_suffix}"

  properties_file_content = <<-EOT
    key.converter=org.apache.kafka.connect.storage.StringConverter
    value.converter=org.apache.kafka.connect.json.JsonConverter
    value.converter.schemas.enable=true
    
    # Enable topic creation by connectors
    topic.creation.enable=true
    
    config.providers=secretsmanager
    config.providers.secretsmanager.class=com.amazonaws.kafka.config.providers.SecretsManagerConfigProvider
    config.providers.secretsmanager.param.region=${var.region}
  EOT

  description = "Worker configuration with Secrets Manager config provider"
}

# Debezium custom plugin
resource "aws_mskconnect_custom_plugin" "debezium" {
  name         = "${var.name_prefix}-debezium-postgres-${var.random_suffix}"
  content_type = "ZIP"

  location {
    s3 {
      bucket_arn = var.s3_bucket_arn
      file_key   = "plugins/debezium-postgres-connector-2.7.3.Final.zip"
    }
  }

  description = "Debezium 2.7.3.Final PostgreSQL source connector"

  depends_on = [null_resource.fetch_debezium_plugin]
}

# Iceberg custom plugin
resource "aws_mskconnect_custom_plugin" "iceberg" {
  name         = "${var.name_prefix}-iceberg-sink-${var.random_suffix}"
  content_type = "ZIP"

  location {
    s3 {
      bucket_arn = var.s3_bucket_arn
      file_key   = "plugins/iceberg-kafka-connect-0.6.19.zip"
    }
  }

  description = "Tabular Iceberg Kafka Connect 0.6.19 sink connector"

  depends_on = [null_resource.fetch_iceberg_plugin]
}

# Track connector config hashes to force replacement on config changes (provider #47004)
resource "terraform_data" "debezium_config_hash" {
  input = sha256(jsonencode({
    connector_class     = "io.debezium.connector.postgresql.PostgresConnector"
    database_hostname   = var.rds_address
    database_port       = var.rds_port
    database_user       = var.rds_master_username
    database_password   = var.rds_secret_arn
    database_dbname     = var.rds_database_name
    topic_prefix        = var.name_prefix
    plugin_name         = "pgoutput"
    slot_name           = "cdc_lakehouse_slot"
    publication_name    = "cdc_publication"
    time_precision_mode = "connect"
    table_include_list  = "public.customers,public.orders,public.order_items"
  }))
}

resource "terraform_data" "iceberg_config_hash" {
  input = sha256(jsonencode({
    connector_class           = "io.tabular.iceberg.connect.IcebergSinkConnector"
    topics                    = "${var.name_prefix}.public.customers,${var.name_prefix}.public.orders,${var.name_prefix}.public.order_items"
    iceberg_control_topic     = "control-iceberg"
    iceberg_catalog_warehouse = "s3://${var.s3_bucket_name}/iceberg/"
    glue_database_name        = var.glue_database_name
    msk_bootstrap_brokers     = var.msk_bootstrap_brokers
  }))
}

# Debezium source connector
resource "aws_mskconnect_connector" "debezium_postgres" {
  name = "${var.name_prefix}-debezium-postgres-${var.random_suffix}"

  kafkaconnect_version = "3.7.x"

  capacity {
    autoscaling {
      mcu_count        = 1
      min_worker_count = 1
      max_worker_count = 2

      scale_in_policy {
        cpu_utilization_percentage = 20
      }

      scale_out_policy {
        cpu_utilization_percentage = 80
      }
    }
  }

  connector_configuration = {
    "connector.class" = "io.debezium.connector.postgresql.PostgresConnector"
    "tasks.max"       = "1"

    # Database connection
    "database.hostname" = var.rds_address
    "database.port"     = tostring(var.rds_port)
    "database.user"     = var.rds_master_username
    # Use Secrets Manager config provider (URL-encode full ARN)
    "database.password" = "$${secretsmanager:${replace(replace(var.rds_secret_arn, ":", "%3A"), "/", "%2F")}:password}"
    "database.dbname"   = var.rds_database_name

    # Topic naming
    "topic.prefix" = var.name_prefix

    # Replication
    "plugin.name"                  = "pgoutput"
    "slot.name"                    = "cdc_lakehouse_slot"
    "publication.name"             = "cdc_publication"
    "publication.autocreate.mode"  = "disabled"
    "time.precision.mode"          = "connect"
    "tombstones.on.delete"         = "true"
    "provide.transaction.metadata" = "false"

    # Topic creation - let Kafka Connect create topics
    "topic.creation.default.replication.factor" = "-1"
    "topic.creation.default.partitions"         = "3"
    "topic.creation.default.cleanup.policy"     = "delete"
    "topic.creation.default.retention.ms"       = "604800000"

    # Converters
    "key.converter"                  = "org.apache.kafka.connect.json.JsonConverter"
    "value.converter"                = "org.apache.kafka.connect.json.JsonConverter"
    "key.converter.schemas.enable"   = "false"
    "value.converter.schemas.enable" = "true"

    # Snapshot
    "snapshot.mode"      = "initial"
    "table.include.list" = "public.customers,public.orders,public.order_items"
  }

  kafka_cluster {
    apache_kafka_cluster {
      bootstrap_servers = var.msk_bootstrap_brokers

      vpc {
        security_groups = var.security_group_ids
        subnets         = var.subnet_ids
      }
    }
  }

  kafka_cluster_client_authentication {
    authentication_type = "IAM"
  }

  kafka_cluster_encryption_in_transit {
    encryption_type = "TLS"
  }

  plugin {
    custom_plugin {
      arn      = aws_mskconnect_custom_plugin.debezium.arn
      revision = aws_mskconnect_custom_plugin.debezium.latest_revision
    }
  }

  service_execution_role_arn = var.debezium_role_arn

  worker_configuration {
    arn      = aws_mskconnect_worker_configuration.debezium.arn
    revision = aws_mskconnect_worker_configuration.debezium.latest_revision
  }

  log_delivery {
    worker_log_delivery {
      cloudwatch_logs {
        enabled   = true
        log_group = aws_cloudwatch_log_group.debezium.name
      }
    }
  }

  depends_on = [aws_mskconnect_custom_plugin.debezium]

  lifecycle {
    replace_triggered_by = [
      terraform_data.debezium_config_hash,
      aws_mskconnect_custom_plugin.debezium.id,
      aws_mskconnect_worker_configuration.debezium.id
    ]
  }
}

# Iceberg sink connector
resource "aws_mskconnect_connector" "iceberg_sink" {
  name = "${var.name_prefix}-iceberg-sink-${var.random_suffix}"

  kafkaconnect_version = "3.7.x"

  capacity {
    autoscaling {
      mcu_count        = 1
      min_worker_count = 1
      max_worker_count = 2

      scale_in_policy {
        cpu_utilization_percentage = 20
      }

      scale_out_policy {
        cpu_utilization_percentage = 80
      }
    }
  }

  connector_configuration = {
    "connector.class" = "io.tabular.iceberg.connect.IcebergSinkConnector"
    "tasks.max"       = "1"

    # Topics to consume
    "topics" = "${var.name_prefix}.public.customers,${var.name_prefix}.public.orders,${var.name_prefix}.public.order_items"

    # Control topic (must be pre-created via bastion)
    "iceberg.control.topic"              = "control-iceberg"
    "iceberg.control.commit.interval-ms" = "60000"
    "iceberg.control.commit.threads"     = "1"

    # Control topic Kafka client IAM auth (explicit, may not inherit from worker)
    "iceberg.kafka.bootstrap.servers"                  = var.msk_bootstrap_brokers
    "iceberg.kafka.security.protocol"                  = "SASL_SSL"
    "iceberg.kafka.sasl.mechanism"                     = "AWS_MSK_IAM"
    "iceberg.kafka.sasl.jaas.config"                   = "software.amazon.msk.auth.iam.IAMLoginModule required;"
    "iceberg.kafka.sasl.client.callback.handler.class" = "software.amazon.msk.auth.iam.IAMClientCallbackHandler"

    # Debezium transform
    "transforms"                        = "debezium"
    "transforms.debezium.type"          = "io.tabular.iceberg.connect.transforms.DebeziumTransform"
    "iceberg.tables.cdc-field"          = "_cdc.op"
    "iceberg.tables.default-id-columns" = "id"

    # Routing (_cdc.source is STRING "public.table", not struct)
    "iceberg.tables.route-field"                                      = "_cdc.source"
    "iceberg.table.${var.glue_database_name}.customers.route-regex"   = "public\\.customers"
    "iceberg.table.${var.glue_database_name}.orders.route-regex"      = "public\\.orders"
    "iceberg.table.${var.glue_database_name}.order_items.route-regex" = "public\\.order_items"

    # Catalog configuration (AWS Glue) - per Tabular 0.6.19 docs
    "iceberg.catalog.catalog-impl"  = "org.apache.iceberg.aws.glue.GlueCatalog"
    "iceberg.catalog.warehouse"     = "s3://${var.s3_bucket_name}/iceberg/"
    "iceberg.catalog.io-impl"       = "org.apache.iceberg.aws.s3.S3FileIO"
    "iceberg.catalog.client.region" = var.region

    # Table auto-creation with format version 2 for upsert support
    "iceberg.tables"                                  = "${var.glue_database_name}.customers,${var.glue_database_name}.orders,${var.glue_database_name}.order_items"
    "iceberg.tables.upsert-mode-enabled"              = "true"
    "iceberg.tables.evolve-schema-enabled"            = "true"
    "iceberg.tables.auto-create-enabled"              = "true"
    "iceberg.tables.default-commit-branch"            = "main"
    "iceberg.tables.auto-create-props.format-version" = "2"

    # Converters (match Debezium output)
    "value.converter"                = "org.apache.kafka.connect.json.JsonConverter"
    "value.converter.schemas.enable" = "true"
    "key.converter"                  = "org.apache.kafka.connect.json.JsonConverter"
    "key.converter.schemas.enable"   = "false"
  }

  kafka_cluster {
    apache_kafka_cluster {
      bootstrap_servers = var.msk_bootstrap_brokers

      vpc {
        security_groups = var.security_group_ids
        subnets         = var.subnet_ids
      }
    }
  }

  kafka_cluster_client_authentication {
    authentication_type = "IAM"
  }

  kafka_cluster_encryption_in_transit {
    encryption_type = "TLS"
  }

  plugin {
    custom_plugin {
      arn      = aws_mskconnect_custom_plugin.iceberg.arn
      revision = aws_mskconnect_custom_plugin.iceberg.latest_revision
    }
  }

  service_execution_role_arn = var.iceberg_role_arn

  log_delivery {
    worker_log_delivery {
      cloudwatch_logs {
        enabled   = true
        log_group = aws_cloudwatch_log_group.iceberg.name
      }
    }
  }

  depends_on = [
    aws_mskconnect_custom_plugin.iceberg,
    aws_mskconnect_connector.debezium_postgres
  ]

  lifecycle {
    replace_triggered_by = [
      terraform_data.iceberg_config_hash,
      aws_mskconnect_custom_plugin.iceberg.id
    ]
  }
}

# CloudWatch log groups for connectors
resource "aws_cloudwatch_log_group" "debezium" {
  name              = "/aws/msk-connect/${var.name_prefix}-debezium-${var.random_suffix}"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "iceberg" {
  name              = "/aws/msk-connect/${var.name_prefix}-iceberg-${var.random_suffix}"
  retention_in_days = 7
}