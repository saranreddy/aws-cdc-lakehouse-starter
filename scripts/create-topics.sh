#!/bin/bash
# Create Kafka topics for MSK Serverless
# MSK Serverless does not support auto-topic creation; topics must be explicitly created

set -e

echo "=== Creating Kafka Topics ==="
echo ""

# Get MSK connection details from Terraform outputs
cd terraform
BOOTSTRAP_BROKERS=$(terraform output -raw msk_bootstrap_brokers_sasl_iam 2>/dev/null)
NAME_PREFIX=$(terraform output -raw name_prefix 2>/dev/null || echo "cdc-lakehouse")
cd ..

if [ -z "$BOOTSTRAP_BROKERS" ]; then
    echo "Error: Could not retrieve MSK bootstrap brokers. Has 'make apply' been run?"
    exit 1
fi

echo "MSK Bootstrap Brokers: $BOOTSTRAP_BROKERS"
echo ""

# Download Kafka tools if not present
KAFKA_VERSION="3.7.0"
KAFKA_HOME="/tmp/kafka"

if [ ! -d "$KAFKA_HOME" ]; then
    echo "Downloading Kafka tools..."
    cd /tmp
    curl -fsSL "https://archive.apache.org/dist/kafka/${KAFKA_VERSION}/kafka_2.13-${KAFKA_VERSION}.tgz" -o kafka.tgz
    tar -xzf kafka.tgz
    mv "kafka_2.13-${KAFKA_VERSION}" kafka
    rm kafka.tgz
    echo "Kafka tools installed to $KAFKA_HOME"
fi

# Download AWS MSK IAM auth library if not present
MSK_IAM_JAR="${KAFKA_HOME}/libs/aws-msk-iam-auth.jar"
if [ ! -f "$MSK_IAM_JAR" ]; then
    echo "Downloading AWS MSK IAM auth library..."
    curl -fsSL "https://github.com/aws/aws-msk-iam-auth/releases/download/v2.3.0/aws-msk-iam-auth-2.3.0-all.jar" \
        -o "$MSK_IAM_JAR"
    echo "IAM auth library installed"
fi

# Create client.properties for IAM authentication
cat > /tmp/client.properties <<EOF
security.protocol=SASL_SSL
sasl.mechanism=AWS_MSK_IAM
sasl.jaas.config=software.amazon.msk.auth.iam.IAMLoginModule required;
sasl.client.callback.handler.class=software.amazon.msk.auth.iam.IAMClientCallbackHandler
EOF

echo ""
echo "Creating Kafka Connect internal topics (compacted)..."

# Kafka Connect internal topics (compacted) - 3 topics
"${KAFKA_HOME}/bin/kafka-topics.sh" \
    --bootstrap-server "$BOOTSTRAP_BROKERS" \
    --command-config /tmp/client.properties \
    --create --if-not-exists \
    --topic connect-offsets \
    --partitions 3 \
    --config cleanup.policy=compact \
    --config min.insync.replicas=2

"${KAFKA_HOME}/bin/kafka-topics.sh" \
    --bootstrap-server "$BOOTSTRAP_BROKERS" \
    --command-config /tmp/client.properties \
    --create --if-not-exists \
    --topic connect-configs \
    --partitions 1 \
    --config cleanup.policy=compact \
    --config min.insync.replicas=2

"${KAFKA_HOME}/bin/kafka-topics.sh" \
    --bootstrap-server "$BOOTSTRAP_BROKERS" \
    --command-config /tmp/client.properties \
    --create --if-not-exists \
    --topic connect-status \
    --partitions 3 \
    --config cleanup.policy=compact \
    --config min.insync.replicas=2

echo "✅ Kafka Connect internal topics created"
echo ""
echo "Creating Debezium schema history topic (compacted)..."

# Debezium schema history (compacted) - 1 topic
"${KAFKA_HOME}/bin/kafka-topics.sh" \
    --bootstrap-server "$BOOTSTRAP_BROKERS" \
    --command-config /tmp/client.properties \
    --create --if-not-exists \
    --topic "${NAME_PREFIX}.schema-history" \
    --partitions 1 \
    --config cleanup.policy=compact \
    --config min.insync.replicas=2

echo "✅ Debezium schema history topic created"
echo ""
echo "Creating Iceberg control topic (compacted)..."

# Iceberg control topic (compacted) - 1 topic
"${KAFKA_HOME}/bin/kafka-topics.sh" \
    --bootstrap-server "$BOOTSTRAP_BROKERS" \
    --command-config /tmp/client.properties \
    --create --if-not-exists \
    --topic control-iceberg \
    --partitions 1 \
    --config cleanup.policy=compact \
    --config min.insync.replicas=2

echo "✅ Iceberg control topic created"
echo ""
echo "Total compacted topics: 5 of 120 limit"
echo ""
echo "Creating CDC data topics (non-compacted)..."

# CDC data topics (non-compacted) - 3 topics
"${KAFKA_HOME}/bin/kafka-topics.sh" \
    --bootstrap-server "$BOOTSTRAP_BROKERS" \
    --command-config /tmp/client.properties \
    --create --if-not-exists \
    --topic "${NAME_PREFIX}.public.customers" \
    --partitions 3

"${KAFKA_HOME}/bin/kafka-topics.sh" \
    --bootstrap-server "$BOOTSTRAP_BROKERS" \
    --command-config /tmp/client.properties \
    --create --if-not-exists \
    --topic "${NAME_PREFIX}.public.orders" \
    --partitions 6

"${KAFKA_HOME}/bin/kafka-topics.sh" \
    --bootstrap-server "$BOOTSTRAP_BROKERS" \
    --command-config /tmp/client.properties \
    --create --if-not-exists \
    --topic "${NAME_PREFIX}.public.order_items" \
    --partitions 6

echo "✅ CDC data topics created"
echo ""
echo "Total non-compacted topic partitions: 15 of 2400 limit"
echo ""
echo "📊 Topic Summary:"

"${KAFKA_HOME}/bin/kafka-topics.sh" \
    --bootstrap-server "$BOOTSTRAP_BROKERS" \
    --command-config /tmp/client.properties \
    --list | grep -E "(connect-|${NAME_PREFIX}|control-iceberg)" || echo "  (none found - topics may be still propagating)"

echo ""
echo "Topics created successfully!"
