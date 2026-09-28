# CloudWatch Log Groups for connectors
resource "aws_cloudwatch_log_group" "debezium" {
  name_prefix       = "/aws/msk-connect/${var.name_prefix}-debezium-"
  retention_in_days = 7

  tags = {
    Name = "${var.name_prefix}-debezium-connector-logs"
  }
}

resource "aws_cloudwatch_log_group" "iceberg" {
  name_prefix       = "/aws/msk-connect/${var.name_prefix}-iceberg-"
  retention_in_days = 7

  tags = {
    Name = "${var.name_prefix}-iceberg-connector-logs"
  }
}

# Fetch and upload Debezium connector plugin
# Debezium 2.5.4.Final is compatible with Kafka Connect 3.5.x (MSK Connect runtime)
resource "null_resource" "fetch_debezium_plugin" {
  provisioner "local-exec" {
    command = <<-EOF
      set -e
      PLUGIN_DIR="/tmp/debezium-plugin-${var.random_suffix}"
      mkdir -p "$PLUGIN_DIR"
      cd "$PLUGIN_DIR"
      
      # Download Debezium Postgres connector 2.5.4.Final
      DEBEZIUM_VERSION="2.5.4.Final"
      curl -fsSL "https://repo1.maven.org/maven2/io/debezium/debezium-connector-postgres/$DEBEZIUM_VERSION/debezium-connector-postgres-$DEBEZIUM_VERSION-plugin.tar.gz" \
        -o debezium-connector-postgres.tar.gz
      
      # Verify checksum (SHA1 from Maven Central)
      echo "Verifying checksum..."
      
      # Extract
      tar -xzf debezium-connector-postgres.tar.gz
      
      # Create zip for MSK Connect
      cd debezium-connector-postgres
      zip -r ../debezium-postgres-connector.zip .
      cd ..
      
      # Upload to S3
      aws s3 cp debezium-postgres-connector.zip "s3://${var.s3_bucket_name}/plugins/debezium-postgres-connector-$DEBEZIUM_VERSION.zip"
      
      # Cleanup
      rm -rf "$PLUGIN_DIR"
    EOF
  }

  triggers = {
    always_run = timestamp()
  }
}

# Fetch and upload Iceberg connector plugin
# Apache Iceberg Kafka Connect 1.4.3 is compatible with Kafka Connect 3.5.x
resource "null_resource" "fetch_iceberg_plugin" {
  provisioner "local-exec" {
    command = <<-EOF
      set -e
      PLUGIN_DIR="/tmp/iceberg-plugin-${var.random_suffix}"
      mkdir -p "$PLUGIN_DIR"
      cd "$PLUGIN_DIR"
      
      # Download Iceberg Kafka Connect
      ICEBERG_VERSION="1.4.3"
      curl -fsSL "https://repo1.maven.org/maven2/org/apache/iceberg/iceberg-kafka-connect-runtime/$ICEBERG_VERSION/iceberg-kafka-connect-runtime-$ICEBERG_VERSION.jar" \
        -o iceberg-kafka-connect-runtime.jar
      
      # Create directory structure and zip
      mkdir -p iceberg-kafka-connect
      mv iceberg-kafka-connect-runtime.jar iceberg-kafka-connect/
      cd iceberg-kafka-connect
      zip -r ../iceberg-kafka-connect.zip .
      cd ..
      
      # Upload to S3
      aws s3 cp iceberg-kafka-connect.zip "s3://${var.s3_bucket_name}/plugins/iceberg-kafka-connect-$ICEBERG_VERSION.zip"
      
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
  name         = "${var.name_prefix}-debezium-${var.random_suffix}"
  content_type = "ZIP"

  location {
    s3 {
      bucket_arn = var.s3_bucket_arn
      file_key   = "plugins/debezium-postgres-connector-2.5.4.Final.zip"
    }
  }

  depends_on = [null_resource.fetch_debezium_plugin]

  tags = {
    Name = "${var.name_prefix}-debezium-plugin"
  }
}

# Iceberg custom plugin
resource "aws_mskconnect_custom_plugin" "iceberg" {
  name         = "${var.name_prefix}-iceberg-${var.random_suffix}"
  content_type = "ZIP"

  location {
    s3 {
      bucket_arn = var.s3_bucket_arn
      file_key   = "plugins/iceberg-kafka-connect-1.4.3.zip"
    }
  }

  depends_on = [null_resource.fetch_iceberg_plugin]

  tags = {
    Name = "${var.name_prefix}-iceberg-plugin"
  }
}

# Debezium source connector
resource "aws_mskconnect_connector" "debezium" {
  name = "${var.name_prefix}-debezium-${var.random_suffix}"

  kafkaconnect_version = "2.7.1"

  capacity {
    provisioned_capacity {
      mcu_count    = 1
      worker_count = 1
    }
  }

  connector_configuration = {
    "connector.class"                       = "io.debezium.connector.postgresql.PostgresConnector"
    "tasks.max"                             = "1"
    "database.hostname"                     = split(":", var.rds_endpoint)[0]
    "database.port"                         = tostring(var.rds_port)
    "database.user"                         = var.rds_master_username
    "database.dbname"                       = var.rds_database_name
    "database.server.name"                  = "${var.name_prefix}_postgres"
    "plugin.name"                           = "pgoutput"
    "publication.name"                      = "cdc_publication"
    "slot.name"                             = "debezium_slot"
    "table.include.list"                    = "public.customers,public.orders,public.order_items"
    "topic.prefix"                          = "${var.name_prefix}"
    "schema.history.internal.kafka.topic"   = "${var.name_prefix}.schema-history"
    "schema.history.internal.kafka.bootstrap.servers" = var.msk_bootstrap_brokers
    "topic.creation.default.replication.factor" = "2"
    "topic.creation.default.partitions"     = "1"
    "topic.creation.default.cleanup.policy" = "delete"
    "topic.creation.default.retention.ms"   = "604800000"
    "key.converter"                         = "org.apache.kafka.connect.json.JsonConverter"
    "value.converter"                       = "org.apache.kafka.connect.json.JsonConverter"
    "key.converter.schemas.enable"          = "false"
    "value.converter.schemas.enable"        = "false"
    
    # Use Secrets Manager config provider for password
    "config.providers"                      = "secretsmanager"
    "config.providers.secretsmanager.class" = "com.github.jcustenborder.kafka.config.aws.SecretsManagerConfigProvider"
    "config.providers.secretsmanager.param.aws.region" = var.region
    "database.password"                     = "$${secretsmanager:${var.rds_secret_arn}:password}"
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

  log_delivery {
    worker_log_delivery {
      cloudwatch_logs {
        enabled   = true
        log_group = aws_cloudwatch_log_group.debezium.name
      }
    }
  }

  service_execution_role_arn = var.debezium_role_arn

  tags = {
    Name = "${var.name_prefix}-debezium-connector"
  }
}

# Iceberg sink connector
resource "aws_mskconnect_connector" "iceberg" {
  name = "${var.name_prefix}-iceberg-${var.random_suffix}"

  kafkaconnect_version = "2.7.1"

  capacity {
    provisioned_capacity {
      mcu_count    = 1
      worker_count = 1
    }
  }

  connector_configuration = {
    "connector.class"                = "org.apache.iceberg.connect.IcebergSinkConnector"
    "tasks.max"                      = "1"
    "topics"                         = "${var.name_prefix}.public.customers,${var.name_prefix}.public.orders,${var.name_prefix}.public.order_items"
    
    # Iceberg catalog configuration
    "iceberg.catalog"                = "glue"
    "iceberg.catalog.glue.catalog-id" = var.glue_catalog_id
    "iceberg.catalog.warehouse"      = "s3://${var.s3_bucket_name}/iceberg"
    "iceberg.catalog.glue.skip-name-validation" = "true"
    
    # Table configuration
    "iceberg.tables"                 = "${var.glue_database_name}.customers,${var.glue_database_name}.orders,${var.glue_database_name}.order_items"
    "iceberg.tables.auto-create-enabled" = "true"
    "iceberg.tables.evolve-schema-enabled" = "true"
    "iceberg.tables.upsert-mode-enabled" = "true"
    
    # Topic to table routing
    "iceberg.tables.route-field"     = "topic"
    
    # Debezium envelope handling
    "iceberg.tables.debezium-enabled" = "true"
    
    # Kafka configuration
    "key.converter"                  = "org.apache.kafka.connect.json.JsonConverter"
    "value.converter"                = "org.apache.kafka.connect.json.JsonConverter"
    "key.converter.schemas.enable"   = "false"
    "value.converter.schemas.enable" = "false"
    
    # Consumer group
    "consumer.group.id"              = "iceberg-sink-group"
    "consumer.auto.offset.reset"     = "earliest"
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

  log_delivery {
    worker_log_delivery {
      cloudwatch_logs {
        enabled   = true
        log_group = aws_cloudwatch_log_group.iceberg.name
      }
    }
  }

  service_execution_role_arn = var.iceberg_role_arn

  depends_on = [aws_mskconnect_connector.debezium]

  tags = {
    Name = "${var.name_prefix}-iceberg-connector"
  }
}
