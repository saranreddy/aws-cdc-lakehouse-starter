# MSK Connect Connectors for CDC Pipeline
# Runtime: Kafka Connect 3.7.1 (Java 11)
# Debezium 2.7.3.Final (Java 11+ compatible)
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
      DEBEZIUM_SHA256="7f8e6c9a3b4d5e2f1a0c9d8e7f6a5b4c3d2e1f0a9b8c7d6e5f4a3b2c1d0e9f8"
      
      echo "Downloading Debezium $DEBEZIUM_VERSION..."
      curl -fsSL "$DEBEZIUM_URL" -o debezium-connector-postgres.tar.gz
      
      # Verify download
      if [ ! -f debezium-connector-postgres.tar.gz ]; then
        echo "Error: Failed to download Debezium connector"
        exit 1
      fi
      
      # Compute and verify SHA256 (skip verification for now, add real hash later)
      ACTUAL_SHA256=$(sha256sum debezium-connector-postgres.tar.gz | cut -d' ' -f1)
      echo "Downloaded SHA256: $ACTUAL_SHA256"
      
      # Extract
      tar -xzf debezium-connector-postgres.tar.gz
      
      # Create zip for MSK Connect
      cd debezium-connector-postgres
      zip -r ../debezium-postgres-connector.zip .
      cd ..
      
      # Compute SHA256 of final zip
      sha256sum debezium-postgres-connector.zip > debezium-postgres-connector.zip.sha256
      
      # Upload to S3
      aws s3 cp debezium-postgres-connector.zip "s3://${var.s3_bucket_name}/plugins/debezium-postgres-connector-$DEBEZIUM_VERSION.zip"
      aws s3 cp debezium-postgres-connector.zip.sha256 "s3://${var.s3_bucket_name}/plugins/debezium-postgres-connector-$DEBEZIUM_VERSION.zip.sha256"
      
      echo "Debezium plugin uploaded to S3"
      
      # Cleanup
      rm -rf "$PLUGIN_DIR"
    EOF
  }

  triggers = {
    always_run = timestamp()
  }

  depends_on = [var.s3_bucket_name]
}

# Fetch and build Tabular Iceberg connector
# Tabular iceberg-kafka-connect 0.6.19 (last stable release before archive)
resource "null_resource" "fetch_iceberg_plugin" {
  provisioner "local-exec" {
    command = <<-EOF
      set -e
      PLUGIN_DIR="/tmp/iceberg-plugin-${var.random_suffix}"
      mkdir -p "$PLUGIN_DIR"
      cd "$PLUGIN_DIR"
      
      # Clone specific release tag
      git clone --depth 1 --branch v0.6.19 https://github.com/tabular-io/iceberg-kafka-connect.git
      cd iceberg-kafka-connect
      
      # Build (requires JDK 11+)
      ./gradlew clean shadowJar
      
      # Package for MSK Connect
      mkdir -p ../iceberg-kafka-connect-package
      cp kafka-connect/build/libs/iceberg-kafka-connect-*-all.jar ../iceberg-kafka-connect-package/
      cd ../iceberg-kafka-connect-package
      zip -r ../iceberg-kafka-connect.zip .
      cd ..
      
      # Compute SHA256
      sha256sum iceberg-kafka-connect.zip > iceberg-kafka-connect.zip.sha256
      
      # Upload to S3
      aws s3 cp iceberg-kafka-connect.zip "s3://${var.s3_bucket_name}/plugins/iceberg-kafka-connect-0.6.19.zip"
      aws s3 cp iceberg-kafka-connect.zip.sha256 "s3://${var.s3_bucket_name}/plugins/iceberg-kafka-connect-0.6.19.zip.sha256"
      
      # Cleanup
      rm -rf "$PLUGIN_DIR"
    EOF
  }

  triggers = {
    always_run = timestamp()
  }
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

# Debezium source connector
resource "aws_mskconnect_connector" "debezium_postgres" {
  name = "${var.name_prefix}-debezium-postgres-${var.random_suffix}"

  kafkaconnect_version = "3.7.1"

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
    "database.hostname"    = var.rds_endpoint
    "database.port"        = tostring(var.rds_port)
    "database.user"        = var.rds_master_username
    "database.password"    = "$${secretManager:${var.rds_secret_arn}:password::}"
    "database.dbname"      = var.rds_database_name
    "database.server.name" = var.name_prefix

    # Replication
    "plugin.name"      = "pgoutput"
    "slot.name"        = "cdc_lakehouse_slot"
    "publication.name" = "cdc_publication"

    # Schema history (compacted topic, pre-created)
    "schema.history.internal.kafka.topic" = "${var.name_prefix}.schema-history"

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

  log_delivery {
    worker_log_delivery {
      cloudwatch_logs {
        enabled   = true
        log_group = aws_cloudwatch_log_group.debezium.name
      }
    }
  }

  depends_on = [aws_mskconnect_custom_plugin.debezium]
}

# Iceberg sink connector
resource "aws_mskconnect_connector" "iceberg_sink" {
  name = "${var.name_prefix}-iceberg-sink-${var.random_suffix}"

  kafkaconnect_version = "3.7.1"

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

    # Topics to consume (pre-created in Serverless)
    "topics" = "${var.name_prefix}.public.customers,${var.name_prefix}.public.orders,${var.name_prefix}.public.order_items"

    # Control topic (compacted, pre-created)
    "iceberg.control.topic"              = "control-iceberg"
    "iceberg.control.commit.interval.ms" = "300000"
    "iceberg.control.commit.threads"     = "1"

    # Catalog configuration (AWS Glue)
    "iceberg.catalog"                 = "glue"
    "iceberg.catalog.glue.catalog-id" = var.glue_catalog_id
    "iceberg.catalog.glue.warehouse"  = "s3://${var.s3_bucket_name}/iceberg/"
    "iceberg.catalog.glue.id"         = var.glue_catalog_id

    # Table configuration
    "iceberg.tables"                       = "${var.glue_database_name}.customers,${var.glue_database_name}.orders,${var.glue_database_name}.order_items"
    "iceberg.tables.upsert-mode-enabled"   = "true"
    "iceberg.tables.evolve-schema-enabled" = "true"
    "iceberg.tables.auto-create-enabled"   = "true"
    "iceberg.tables.default-commit-branch" = "main"

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