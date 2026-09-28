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