#!/bin/bash
set -e

echo "=== Seeding Database ==="
echo ""

# Get RDS and infrastructure details from Terraform outputs
cd terraform
RDS_ENDPOINT=$(terraform output -raw rds_endpoint 2>/dev/null | cut -d: -f1)
RDS_PORT=$(terraform output -raw rds_port 2>/dev/null)
RDS_DATABASE=$(terraform output -raw rds_database_name 2>/dev/null)
RDS_USERNAME=$(terraform output -raw rds_master_username 2>/dev/null)
RDS_SECRET_ARN=$(terraform output -raw rds_secret_arn 2>/dev/null)
BASTION_INSTANCE_ID=$(terraform output -raw bastion_instance_id 2>/dev/null)
MSK_BOOTSTRAP=$(terraform output -raw msk_bootstrap_brokers 2>/dev/null)
REGION=$(terraform output -raw region 2>/dev/null)
cd ..

if [ -z "$RDS_ENDPOINT" ]; then
    echo "Error: Could not retrieve outputs. Has 'make apply-infra' been run?"
    exit 1
fi

# Trap to cleanup on exit
cleanup() {
    local exit_code=$?
    if [ -n "$SSM_PID" ]; then
        echo ""
        echo "Cleaning up SSM tunnel..."
        kill "$SSM_PID" 2>/dev/null || true
        wait "$SSM_PID" 2>/dev/null || true
        # Also kill any orphaned session-manager-plugin processes
        pkill -f "session-manager-plugin.*$BASTION_INSTANCE_ID" 2>/dev/null || true
    fi
    exit $exit_code
}
trap cleanup EXIT INT TERM

echo "Connecting to RDS via bastion..."
echo "  Endpoint: $RDS_ENDPOINT:$RDS_PORT"
echo "  Database: $RDS_DATABASE"
echo "  Username: $RDS_USERNAME"
echo ""

# Get password from Secrets Manager
echo "Retrieving password from Secrets Manager..."
if ! PGPASSWORD_VALUE=$(aws secretsmanager get-secret-value \
    --secret-id "$RDS_SECRET_ARN" \
    --region "$REGION" \
    --query SecretString \
    --output text 2>/dev/null); then
    echo "Error: Failed to retrieve RDS password from Secrets Manager"
    exit 1
fi

# Parse JSON to extract password (safe, doesn't use grep)
PGPASSWORD_VALUE=$(echo "$PGPASSWORD_VALUE" | python3 -c "import sys, json; print(json.load(sys.stdin)['password'])" 2>/dev/null)
if [ -z "$PGPASSWORD_VALUE" ]; then
    echo "Error: Failed to parse password from secret"
    exit 1
fi
export PGPASSWORD="$PGPASSWORD_VALUE"

# Connect via SSM port forwarding
echo "Starting SSM port forward session..."
LOCAL_PORT=5433
aws ssm start-session \
    --target "$BASTION_INSTANCE_ID" \
    --document-name AWS-StartPortForwardingSessionToRemoteHost \
    --parameters "{\"host\":[\"$RDS_ENDPOINT\"],\"portNumber\":[\"$RDS_PORT\"],\"localPortNumber\":[\"$LOCAL_PORT\"]}" \
    >/dev/null 2>&1 &
SSM_PID=$!

# Wait for tunnel to be ready
echo "Waiting for tunnel..."
RETRIES=0
MAX_RETRIES=30
while [ $RETRIES -lt $MAX_RETRIES ]; do
    if nc -z localhost $LOCAL_PORT 2>/dev/null; then
        echo "Tunnel ready!"
        break
    fi
    RETRIES=$((RETRIES + 1))
    sleep 1
done

if [ $RETRIES -eq $MAX_RETRIES ]; then
    echo "Error: Tunnel failed to start"
    exit 1
fi

# Execute SQL (idempotent - recreate publication without dropping tables)
echo ""
echo "Creating schema and seeding data (idempotent)..."

# Check wal_level is set to logical
echo "Verifying wal_level is set to 'logical'..."
WAL_LEVEL=$(PGPASSWORD="$PGPASSWORD_VALUE" psql -h localhost -p $LOCAL_PORT -U "$RDS_USERNAME" -d "$RDS_DATABASE" -tAc "show wal_level")
if [ "$WAL_LEVEL" != "logical" ]; then
    echo "Error: wal_level is '$WAL_LEVEL', expected 'logical'"
    echo "Logical replication requires wal_level=logical in the RDS parameter group"
    exit 1
fi
echo "wal_level check passed: $WAL_LEVEL"

# Run SQL with ON_ERROR_STOP to fail on any error
PGPASSWORD="$PGPASSWORD_VALUE" \
psql -h localhost -p $LOCAL_PORT -U "$RDS_USERNAME" -d "$RDS_DATABASE" -v ON_ERROR_STOP=1 <<'EOF'
-- Create tables (IF NOT EXISTS for idempotency)
CREATE TABLE IF NOT EXISTS public.customers (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    email VARCHAR(255) UNIQUE NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS public.orders (
    id SERIAL PRIMARY KEY,
    customer_id INTEGER NOT NULL REFERENCES public.customers(id),
    order_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    total_amount DECIMAL(10, 2) NOT NULL,
    status VARCHAR(50) DEFAULT 'pending'
);

CREATE TABLE IF NOT EXISTS public.order_items (
    id SERIAL PRIMARY KEY,
    order_id INTEGER NOT NULL REFERENCES public.orders(id),
    product_name VARCHAR(255) NOT NULL,
    quantity INTEGER NOT NULL,
    unit_price DECIMAL(10, 2) NOT NULL
);

-- Insert seed data (idempotent - only if tables are empty)
INSERT INTO public.customers (name, email)
SELECT * FROM (VALUES
    ('Alice Anderson', 'alice@example.com'),
    ('Bob Brown', 'bob@example.com'),
    ('Charlie Chen', 'charlie@example.com'),
    ('Diana Davis', 'diana@example.com'),
    ('Eve Evans', 'eve@example.com')
) AS v(name, email)
WHERE NOT EXISTS (SELECT 1 FROM public.customers LIMIT 1);

INSERT INTO public.orders (customer_id, order_date, total_amount, status)
SELECT * FROM (VALUES
    (1, '2024-01-15 10:30:00'::timestamp, 99.99, 'completed'),
    (2, '2024-01-16 14:15:00'::timestamp, 149.50, 'completed'),
    (1, '2024-01-17 09:00:00'::timestamp, 79.99, 'pending'),
    (3, '2024-01-18 16:45:00'::timestamp, 199.99, 'completed'),
    (4, '2024-01-19 11:20:00'::timestamp, 59.99, 'shipped')
) AS v(customer_id, order_date, total_amount, status)
WHERE NOT EXISTS (SELECT 1 FROM public.orders LIMIT 1);

INSERT INTO public.order_items (order_id, product_name, quantity, unit_price)
SELECT * FROM (VALUES
    (1, 'Widget A', 2, 29.99),
    (1, 'Widget B', 1, 39.99),
    (2, 'Widget C', 3, 49.50),
    (3, 'Widget A', 1, 29.99),
    (3, 'Widget D', 1, 49.99),
    (4, 'Widget E', 2, 99.99),
    (5, 'Widget B', 1, 39.99),
    (5, 'Widget A', 1, 19.99)
) AS v(order_id, product_name, quantity, unit_price)
WHERE NOT EXISTS (SELECT 1 FROM public.order_items LIMIT 1);

-- Create publication (idempotent - only if it doesn't exist)
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'cdc_publication') THEN
        CREATE PUBLICATION cdc_publication FOR TABLE 
            public.customers, 
            public.orders, 
            public.order_items;
        RAISE NOTICE 'Publication created';
    ELSE
        RAISE NOTICE 'Publication already exists';
    END IF;
END
$$;

-- Verify
SELECT 'Customers: ' || COUNT(*) FROM public.customers
UNION ALL
SELECT 'Orders: ' || COUNT(*) FROM public.orders
UNION ALL
SELECT 'Order Items: ' || COUNT(*) FROM public.order_items;
EOF

echo ""
echo "Database seeding complete!"
echo ""

# Create control topic for Iceberg sink via bastion
echo "=== Creating Iceberg control topic ==="
echo ""
echo "The Iceberg sink requires a control topic to exist before it starts."
echo "Creating topic 'control-iceberg' via SSM send-command on bastion..."
echo ""

# Create a script on the bastion to create the Kafka topic
KAFKA_SCRIPT=$(cat <<'KAFKA_EOF'
#!/bin/bash
set -euo pipefail

# Wait for cloud-init to complete
cloud-init status --wait >/dev/null 2>&1 || true

# Ensure Java is installed
command -v java >/dev/null || dnf install -y java-17-amazon-corretto-headless

# Download and verify Kafka CLI if not already fully installed
if [ ! -x /opt/kafka/bin/kafka-topics.sh ] || [ ! -f /opt/kafka/libs/aws-msk-iam-auth.jar ]; then
    echo "Installing Kafka CLI and aws-msk-iam-auth..."
    
    # Create temp directory for downloads
    TEMP_DIR=$(mktemp -d)
    cd "$TEMP_DIR"
    
    # Download Kafka with retry (try dlcdn first for 4.x, fallback to archive)
    KAFKA_VERSION="4.3.1"
    KAFKA_FILENAME="kafka_2.13-${KAFKA_VERSION}.tgz"
    KAFKA_SHA512="c7d7b2318cb51aa0c61d3246a51c349210073c5c9b754947ef965a439f2f939e8600f204e134a75ac31faf3829c9370960ef7c6a9886c8a1dbf0339a21f4c54c"
    
    echo "Downloading Kafka ${KAFKA_VERSION} (requires Java 17, which is pre-installed)..."
    MAX_RETRIES=3
    RETRY_COUNT=0
    DOWNLOAD_SUCCESS=0
    CURL_TIMEOUT=600  # 10 minutes per attempt
    
    # Try dlcdn.apache.org first (faster CDN, hosts current releases)
    while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        echo "  Attempt $((RETRY_COUNT + 1))/$MAX_RETRIES: Trying dlcdn.apache.org..."
        if curl -fsSL -m $CURL_TIMEOUT "https://dlcdn.apache.org/kafka/${KAFKA_VERSION}/${KAFKA_FILENAME}" -o kafka.tgz 2>/dev/null; then
            echo "  Download complete from dlcdn.apache.org"
            DOWNLOAD_SUCCESS=1
            break
        fi
        RETRY_COUNT=$((RETRY_COUNT + 1))
        [ $RETRY_COUNT -lt $MAX_RETRIES ] && sleep 5
    done
    
    # Fallback to downloads.apache.org (mirror selection, also fast)
    if [ $DOWNLOAD_SUCCESS -eq 0 ]; then
        echo "  dlcdn failed, trying downloads.apache.org..."
        RETRY_COUNT=0
        while [ $RETRY_COUNT -lt 2 ]; do
            echo "  Attempt $((RETRY_COUNT + 1))/2: Downloading..."
            if curl -fsSL -m $CURL_TIMEOUT "https://downloads.apache.org/kafka/${KAFKA_VERSION}/${KAFKA_FILENAME}" -o kafka.tgz 2>/dev/null; then
                echo "  Download complete from downloads.apache.org"
                DOWNLOAD_SUCCESS=1
                break
            fi
            RETRY_COUNT=$((RETRY_COUNT + 1))
            [ $RETRY_COUNT -lt 2 ] && sleep 5
        done
    fi
    
    if [ $DOWNLOAD_SUCCESS -eq 0 ]; then
        echo "Error: Failed to download Kafka after trying both mirrors"
        exit 1
    fi
    
    # Verify SHA512 (AL2023 has sha512sum)
    ACTUAL_SHA512=$(sha512sum kafka.tgz | cut -d' ' -f1)
    echo "Expected SHA512: $KAFKA_SHA512"
    echo "Actual SHA512:   $ACTUAL_SHA512"
    
    if [ "$ACTUAL_SHA512" != "$KAFKA_SHA512" ]; then
      echo "Error: Kafka SHA512 mismatch!"
      exit 1
    fi
    
    echo "Kafka SHA512 verified successfully"
    
    # Extract to temp location
    tar -xzf kafka.tgz
    
    # Install aws-msk-iam-auth (try GitHub releases, fallback to Maven Central)
    IAM_AUTH_VERSION="1.1.9"
    IAM_AUTH_SHA256="16b3fbb2fbc7f0a5e60f2b8152b85c4892ed2459595a6400bc29126d98dcdf78"
    
    echo "Downloading aws-msk-iam-auth ${IAM_AUTH_VERSION}..."
    DOWNLOAD_SUCCESS=0
    
    # Try GitHub releases first
    if curl -fsSL "https://github.com/aws/aws-msk-iam-auth/releases/download/v${IAM_AUTH_VERSION}/aws-msk-iam-auth-${IAM_AUTH_VERSION}-all.jar" -o aws-msk-iam-auth.jar 2>/dev/null; then
        echo "  Downloaded from GitHub releases"
        DOWNLOAD_SUCCESS=1
    else
        # Fallback to Maven Central
        echo "  GitHub failed, trying Maven Central..."
        if curl -fsSL "https://repo1.maven.org/maven2/software/amazon/msk/aws-msk-iam-auth/${IAM_AUTH_VERSION}/aws-msk-iam-auth-${IAM_AUTH_VERSION}-all.jar" -o aws-msk-iam-auth.jar; then
            echo "  Downloaded from Maven Central"
            DOWNLOAD_SUCCESS=1
        fi
    fi
    
    if [ $DOWNLOAD_SUCCESS -eq 0 ]; then
        echo "Error: Failed to download aws-msk-iam-auth"
        exit 1
    fi
    
    # Verify SHA256
    ACTUAL_SHA256=$(sha256sum aws-msk-iam-auth.jar | cut -d' ' -f1)
    echo "Expected SHA256: $IAM_AUTH_SHA256"
    echo "Actual SHA256:   $ACTUAL_SHA256"
    
    if [ "$ACTUAL_SHA256" != "$IAM_AUTH_SHA256" ]; then
      echo "Error: aws-msk-iam-auth SHA256 mismatch!"
      exit 1
    fi
    
    echo "aws-msk-iam-auth SHA256 verified successfully"
    
    # Move into place atomically
    sudo mkdir -p "kafka_2.13-${KAFKA_VERSION}/libs"
    sudo mv aws-msk-iam-auth.jar "kafka_2.13-${KAFKA_VERSION}/libs/"
    sudo rm -rf /opt/kafka
    sudo mkdir -p /opt
    sudo mv "kafka_2.13-${KAFKA_VERSION}" /opt/kafka
    
    # Cleanup
    cd /
    rm -rf "$TEMP_DIR"
    
    echo "Kafka and aws-msk-iam-auth installed successfully"
fi

# Create client.properties for IAM auth
cat > /tmp/client.properties <<'EOF'
security.protocol=SASL_SSL
sasl.mechanism=AWS_MSK_IAM
sasl.jaas.config=software.amazon.msk.auth.iam.IAMLoginModule required;
sasl.client.callback.handler.class=software.amazon.msk.auth.iam.IAMClientCallbackHandler
EOF

# Bootstrap servers are embedded in the script
BOOTSTRAP_SERVERS="MSK_BOOTSTRAP_PLACEHOLDER"

# Create control topic (idempotent, plain 1-partition topic)
echo "Creating control-iceberg topic..."
/opt/kafka/bin/kafka-topics.sh \
    --bootstrap-server "$BOOTSTRAP_SERVERS" \
    --command-config /tmp/client.properties \
    --create \
    --if-not-exists \
    --topic control-iceberg \
    --partitions 1

echo "Topic created successfully!"

# Verify
/opt/kafka/bin/kafka-topics.sh \
    --bootstrap-server "$BOOTSTRAP_SERVERS" \
    --command-config /tmp/client.properties \
    --describe \
    --topic control-iceberg
KAFKA_EOF
)

# Replace the bootstrap servers placeholder with actual value
KAFKA_SCRIPT="${KAFKA_SCRIPT//MSK_BOOTSTRAP_PLACEHOLDER/$MSK_BOOTSTRAP}"

# Build SSM parameters JSON with python3 (safe from backslash-newline joining)
SSM_PARAMS_FILE=$(mktemp)
printf '%s' "$KAFKA_SCRIPT" | python3 -c 'import json,sys; print(json.dumps({"commands":[sys.stdin.read()],"executionTimeout":["2400"]}))' > "$SSM_PARAMS_FILE"

# Send command to bastion to create topic
echo "Sending command to bastion..."
COMMAND_ID=$(aws ssm send-command \
    --instance-ids "$BASTION_INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters "file://$SSM_PARAMS_FILE" \
    --region "$REGION" \
    --output text \
    --query 'Command.CommandId')

rm -f "$SSM_PARAMS_FILE"

if [ -z "$COMMAND_ID" ]; then
    echo "Error: Failed to send SSM command"
    exit 1
fi

echo "Command ID: $COMMAND_ID"
echo "Waiting for command to complete (up to 45 minutes for Kafka download)..."

# Poll for command status using wall-clock time
MAX_WAIT=2700
START_TIME=$(date +%s)
ELAPSED=0
while [ $ELAPSED -lt $MAX_WAIT ]; do
    STATUS=$(aws ssm get-command-invocation \
        --command-id "$COMMAND_ID" \
        --instance-id "$BASTION_INSTANCE_ID" \
        --region "$REGION" \
        --query 'Status' \
        --output text 2>/dev/null || echo "Pending")
    
    if [ "$STATUS" = "Success" ]; then
        echo "Topic creation succeeded!"
        
        # Show output
        echo ""
        echo "Command output:"
        aws ssm get-command-invocation \
            --command-id "$COMMAND_ID" \
            --instance-id "$BASTION_INSTANCE_ID" \
            --region "$REGION" \
            --query 'StandardOutputContent' \
            --output text 2>/dev/null || true
        break
    elif [ "$STATUS" = "Failed" ] || [ "$STATUS" = "Cancelled" ] || [ "$STATUS" = "TimedOut" ]; then
        echo "Error: Command failed with status: $STATUS"
        echo ""
        echo "Error output:"
        aws ssm get-command-invocation \
            --command-id "$COMMAND_ID" \
            --instance-id "$BASTION_INSTANCE_ID" \
            --region "$REGION" \
            --query 'StandardErrorContent' \
            --output text 2>/dev/null || true
        exit 1
    fi
    
    # Print progress every 30 seconds
    if [ $((ELAPSED % 30)) -eq 0 ]; then
        echo "  Still waiting... (${ELAPSED}s elapsed, status: $STATUS)"
    fi
    sleep 5
    ELAPSED=$(($(date +%s) - START_TIME))
done

if [ $ELAPSED -ge $MAX_WAIT ]; then
    echo "Error: Command timed out after ${MAX_WAIT}s"
    exit 1
fi

echo ""
echo "Seeding complete!"
echo ""
echo "Next step: Run 'make apply-connectors' to enable the connectors"
