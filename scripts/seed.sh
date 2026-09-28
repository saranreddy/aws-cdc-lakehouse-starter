#!/bin/bash
set -e

echo "=== Pre-seed: Creating Kafka Topics ==="
./scripts/create-topics.sh || {
    echo "Warning: Topic creation failed. Continuing with seed..."
    echo "Topics may already exist or will be auto-created by connectors."
}

echo ""
echo "=== Seeding Database ==="
echo ""

# Get RDS connection details from Terraform outputs
cd terraform
RDS_ENDPOINT=$(terraform output -raw rds_endpoint 2>/dev/null | cut -d: -f1)
RDS_PORT=$(terraform output -raw rds_port 2>/dev/null)
RDS_DATABASE=$(terraform output -raw rds_database_name 2>/dev/null)
RDS_USERNAME=$(terraform output -raw rds_master_username 2>/dev/null)
RDS_SECRET_ARN=$(terraform output -raw rds_secret_arn 2>/dev/null)
BASTION_INSTANCE_ID=$(terraform output -raw bastion_instance_id 2>/dev/null)
cd ..

if [ -z "$RDS_ENDPOINT" ]; then
    echo "Error: Could not retrieve RDS endpoint. Has 'make apply' been run?"
    exit 1
fi

echo "Connecting to RDS via bastion..."
echo "  Endpoint: $RDS_ENDPOINT:$RDS_PORT"
echo "  Database: $RDS_DATABASE"
echo "  Username: $RDS_USERNAME"
echo ""

# Get password from Secrets Manager
echo "Retrieving password from Secrets Manager..."
PGPASSWORD_VALUE=$(aws secretsmanager get-secret-value --secret-id "$RDS_SECRET_ARN" --query SecretString --output text | grep -o '"password":"[^"]*' | cut -d'"' -f4)
export PGPASSWORD="$PGPASSWORD_VALUE"

# Connect via SSM port forwarding
echo "Starting SSM port forward session..."
LOCAL_PORT=5433
aws ssm start-session \
    --target "$BASTION_INSTANCE_ID" \
    --document-name AWS-StartPortForwardingSessionToRemoteHost \
    --parameters "{\"host\":[\"$RDS_ENDPOINT\"],\"portNumber\":[\"$RDS_PORT\"],\"localPortNumber\":[\"$LOCAL_PORT\"]}" &
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
    kill $SSM_PID 2>/dev/null || true
    exit 1
fi

# Execute SQL
echo ""
echo "Creating schema and seeding data..."
psql -h localhost -p $LOCAL_PORT -U "$RDS_USERNAME" -d "$RDS_DATABASE" <<'EOF'
-- Drop existing tables if they exist
DROP TABLE IF EXISTS public.order_items CASCADE;
DROP TABLE IF EXISTS public.orders CASCADE;
DROP TABLE IF EXISTS public.customers CASCADE;

-- Create customers table
CREATE TABLE public.customers (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    email VARCHAR(255) UNIQUE NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Create orders table
CREATE TABLE public.orders (
    id SERIAL PRIMARY KEY,
    customer_id INTEGER NOT NULL REFERENCES public.customers(id),
    order_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    total_amount DECIMAL(10, 2) NOT NULL,
    status VARCHAR(50) DEFAULT 'pending'
);

-- Create order_items table
CREATE TABLE public.order_items (
    id SERIAL PRIMARY KEY,
    order_id INTEGER NOT NULL REFERENCES public.orders(id),
    product_name VARCHAR(255) NOT NULL,
    quantity INTEGER NOT NULL,
    unit_price DECIMAL(10, 2) NOT NULL
);

-- Insert seed data
INSERT INTO public.customers (name, email) VALUES
    ('Alice Anderson', 'alice@example.com'),
    ('Bob Brown', 'bob@example.com'),
    ('Charlie Chen', 'charlie@example.com'),
    ('Diana Davis', 'diana@example.com'),
    ('Eve Evans', 'eve@example.com');

INSERT INTO public.orders (customer_id, order_date, total_amount, status) VALUES
    (1, '2024-01-15 10:30:00', 99.99, 'completed'),
    (2, '2024-01-16 14:15:00', 149.50, 'completed'),
    (1, '2024-01-17 09:00:00', 79.99, 'pending'),
    (3, '2024-01-18 16:45:00', 199.99, 'completed'),
    (4, '2024-01-19 11:20:00', 59.99, 'shipped');

INSERT INTO public.order_items (order_id, product_name, quantity, unit_price) VALUES
    (1, 'Widget A', 2, 29.99),
    (1, 'Widget B', 1, 39.99),
    (2, 'Widget C', 3, 49.50),
    (3, 'Widget A', 1, 29.99),
    (3, 'Widget D', 1, 49.99),
    (4, 'Widget E', 2, 99.99),
    (5, 'Widget B', 1, 39.99),
    (5, 'Widget A', 1, 19.99);

-- Create publication for Debezium
DROP PUBLICATION IF EXISTS cdc_publication;
CREATE PUBLICATION cdc_publication FOR TABLE 
    public.customers, 
    public.orders, 
    public.order_items;

-- Verify
SELECT 'Customers: ' || COUNT(*) FROM public.customers
UNION ALL
SELECT 'Orders: ' || COUNT(*) FROM public.orders
UNION ALL
SELECT 'Order Items: ' || COUNT(*) FROM public.order_items;
EOF

# Cleanup
echo ""
echo "Cleaning up tunnel..."
kill $SSM_PID 2>/dev/null || true
wait $SSM_PID 2>/dev/null || true

echo ""
echo "Seeding complete!"
echo ""
echo "Note: Debezium will capture changes once it connects."
echo "      Initial snapshot may take a few minutes."
