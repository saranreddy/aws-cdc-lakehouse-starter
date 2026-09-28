#!/bin/bash
set -e

echo "=== Smoke Test ==="
echo ""

# Get outputs
cd terraform
RDS_ENDPOINT=$(terraform output -raw rds_endpoint 2>/dev/null | cut -d: -f1)
RDS_PORT=$(terraform output -raw rds_port 2>/dev/null)
RDS_DATABASE=$(terraform output -raw rds_database_name 2>/dev/null)
RDS_USERNAME=$(terraform output -raw rds_master_username 2>/dev/null)
RDS_SECRET_ARN=$(terraform output -raw rds_secret_arn 2>/dev/null)
BASTION_INSTANCE_ID=$(terraform output -raw bastion_instance_id 2>/dev/null)
ATHENA_DATABASE=$(terraform output -raw glue_database_name 2>/dev/null)
ATHENA_WORKGROUP=$(terraform output -raw athena_workgroup_name 2>/dev/null)
REGION=$(terraform output -raw region 2>/dev/null)
cd ..

if [ -z "$RDS_ENDPOINT" ] || [ -z "$ATHENA_DATABASE" ]; then
    echo "Error: Could not retrieve required outputs. Has 'make apply' been run?"
    exit 1
fi

# Generate unique marker
MARKER="smoke_test_$$_$(date +%s)"
echo "Test marker: $MARKER"
echo ""

# Get RDS password
export PGPASSWORD=$(aws secretsmanager get-secret-value --secret-id "$RDS_SECRET_ARN" --query SecretString --output text | grep -o '"password":"[^"]*' | cut -d'"' -f4)

# Start SSM tunnel
echo "Starting SSM port forward..."
LOCAL_PORT=5433
aws ssm start-session \
    --target "$BASTION_INSTANCE_ID" \
    --document-name AWS-StartPortForwardingSessionToRemoteHost \
    --parameters "{\"host\":[\"$RDS_ENDPOINT\"],\"portNumber\":[\"$RDS_PORT\"],\"localPortNumber\":[\"$LOCAL_PORT\"]}" \
    >/dev/null 2>&1 &
SSM_PID=$!

# Wait for tunnel
RETRIES=0
MAX_RETRIES=30
while [ $RETRIES -lt $MAX_RETRIES ]; do
    if nc -z localhost $LOCAL_PORT 2>/dev/null; then
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

# Test 1: Insert a row with unique marker
echo "Test 1: Insert row in Postgres..."
START_TIME=$(date +%s)
psql -h localhost -p $LOCAL_PORT -U "$RDS_USERNAME" -d "$RDS_DATABASE" -c \
    "INSERT INTO public.customers (name, email) VALUES ('Smoke Test', '$MARKER@example.com');" \
    >/dev/null

CUSTOMER_ID=$(psql -h localhost -p $LOCAL_PORT -U "$RDS_USERNAME" -d "$RDS_DATABASE" -t -c \
    "SELECT id FROM public.customers WHERE email = '$MARKER@example.com';")
CUSTOMER_ID=$(echo "$CUSTOMER_ID" | xargs)
echo "  Inserted customer ID: $CUSTOMER_ID"

# Test 2: Poll Athena until row appears
echo ""
echo "Test 2: Polling Athena for row (max 5 minutes)..."
POLL_START=$(date +%s)
MAX_WAIT=300
FOUND=0

while [ $(($(date +%s) - POLL_START)) -lt $MAX_WAIT ]; do
    QUERY_ID=$(aws athena start-query-execution \
        --query-string "SELECT * FROM customers WHERE email = '$MARKER@example.com'" \
        --query-execution-context "Database=$ATHENA_DATABASE" \
        --work-group "$ATHENA_WORKGROUP" \
        --region "$REGION" \
        --query 'QueryExecutionId' \
        --output text 2>/dev/null)
    
    if [ -n "$QUERY_ID" ]; then
        # Wait for query to complete
        sleep 2
        STATUS=""
        WAIT_COUNT=0
        while [ $WAIT_COUNT -lt 15 ]; do
            STATUS=$(aws athena get-query-execution \
                --query-execution-id "$QUERY_ID" \
                --region "$REGION" \
                --query 'QueryExecution.Status.State' \
                --output text 2>/dev/null)
            
            if [ "$STATUS" = "SUCCEEDED" ]; then
                break
            elif [ "$STATUS" = "FAILED" ] || [ "$STATUS" = "CANCELLED" ]; then
                break
            fi
            sleep 1
            WAIT_COUNT=$((WAIT_COUNT + 1))
        done
        
        if [ "$STATUS" = "SUCCEEDED" ]; then
            RESULTS=$(aws athena get-query-results \
                --query-execution-id "$QUERY_ID" \
                --region "$REGION" \
                --output text 2>/dev/null | grep -c "$MARKER" || echo "0")
            
            if [ "$RESULTS" -gt 0 ]; then
                FOUND=1
                POLL_END=$(date +%s)
                LATENCY=$((POLL_END - START_TIME))
                echo "  Row found in Athena! Latency: ${LATENCY}s"
                break
            fi
        fi
    fi
    
    echo -n "."
    sleep 5
done

if [ $FOUND -eq 0 ]; then
    echo ""
    echo "Error: Row not found in Athena after ${MAX_WAIT}s"
    echo "This may indicate:"
    echo "  - Debezium connector is not running"
    echo "  - Iceberg connector is not running"
    echo "  - Network connectivity issues"
    echo "  - Connector configuration issues"
    kill $SSM_PID 2>/dev/null || true
    exit 1
fi

# Test 3: Update the row
echo ""
echo "Test 3: Update row in Postgres..."
psql -h localhost -p $LOCAL_PORT -U "$RDS_USERNAME" -d "$RDS_DATABASE" -c \
    "UPDATE public.customers SET name = 'Smoke Test Updated' WHERE id = $CUSTOMER_ID;" \
    >/dev/null

# Poll for update
echo "  Polling Athena for update..."
UPDATE_START=$(date +%s)
UPDATE_FOUND=0

while [ $(($(date +%s) - UPDATE_START)) -lt $MAX_WAIT ]; do
    QUERY_ID=$(aws athena start-query-execution \
        --query-string "SELECT name FROM customers WHERE email = '$MARKER@example.com'" \
        --query-execution-context "Database=$ATHENA_DATABASE" \
        --work-group "$ATHENA_WORKGROUP" \
        --region "$REGION" \
        --query 'QueryExecutionId' \
        --output text 2>/dev/null)
    
    if [ -n "$QUERY_ID" ]; then
        sleep 2
        STATUS=""
        WAIT_COUNT=0
        while [ $WAIT_COUNT -lt 15 ]; do
            STATUS=$(aws athena get-query-execution \
                --query-execution-id "$QUERY_ID" \
                --region "$REGION" \
                --query 'QueryExecution.Status.State' \
                --output text 2>/dev/null)
            
            if [ "$STATUS" = "SUCCEEDED" ]; then
                break
            elif [ "$STATUS" = "FAILED" ] || [ "$STATUS" = "CANCELLED" ]; then
                break
            fi
            sleep 1
            WAIT_COUNT=$((WAIT_COUNT + 1))
        done
        
        if [ "$STATUS" = "SUCCEEDED" ]; then
            RESULTS=$(aws athena get-query-results \
                --query-execution-id "$QUERY_ID" \
                --region "$REGION" \
                --output text 2>/dev/null | grep -c "Updated" || echo "0")
            
            if [ "$RESULTS" -gt 0 ]; then
                UPDATE_FOUND=1
                UPDATE_END=$(date +%s)
                UPDATE_LATENCY=$((UPDATE_END - UPDATE_START))
                echo "  Update found! Latency: ${UPDATE_LATENCY}s"
                break
            fi
        fi
    fi
    
    echo -n "."
    sleep 5
done

if [ $UPDATE_FOUND -eq 0 ]; then
    echo ""
    echo "Warning: Update not reflected in Athena after ${MAX_WAIT}s"
fi

# Test 4: Delete the row
echo ""
echo "Test 4: Delete row in Postgres..."
psql -h localhost -p $LOCAL_PORT -U "$RDS_USERNAME" -d "$RDS_DATABASE" -c \
    "DELETE FROM public.customers WHERE id = $CUSTOMER_ID;" \
    >/dev/null

# Poll for deletion
echo "  Polling Athena for deletion..."
DELETE_START=$(date +%s)
DELETE_FOUND=0

while [ $(($(date +%s) - DELETE_START)) -lt $MAX_WAIT ]; do
    QUERY_ID=$(aws athena start-query-execution \
        --query-string "SELECT * FROM customers WHERE email = '$MARKER@example.com'" \
        --query-execution-context "Database=$ATHENA_DATABASE" \
        --work-group "$ATHENA_WORKGROUP" \
        --region "$REGION" \
        --query 'QueryExecutionId' \
        --output text 2>/dev/null)
    
    if [ -n "$QUERY_ID" ]; then
        sleep 2
        STATUS=""
        WAIT_COUNT=0
        while [ $WAIT_COUNT -lt 15 ]; do
            STATUS=$(aws athena get-query-execution \
                --query-execution-id "$QUERY_ID" \
                --region "$REGION" \
                --query 'QueryExecution.Status.State' \
                --output text 2>/dev/null)
            
            if [ "$STATUS" = "SUCCEEDED" ]; then
                break
            elif [ "$STATUS" = "FAILED" ] || [ "$STATUS" = "CANCELLED" ]; then
                break
            fi
            sleep 1
            WAIT_COUNT=$((WAIT_COUNT + 1))
        done
        
        if [ "$STATUS" = "SUCCEEDED" ]; then
            RESULTS=$(aws athena get-query-results \
                --query-execution-id "$QUERY_ID" \
                --region "$REGION" \
                --output text 2>/dev/null | grep -c "$MARKER" || echo "0")
            
            if [ "$RESULTS" -eq 0 ]; then
                DELETE_FOUND=1
                DELETE_END=$(date +%s)
                DELETE_LATENCY=$((DELETE_END - DELETE_START))
                echo "  Deletion confirmed! Latency: ${DELETE_LATENCY}s"
                break
            fi
        fi
    fi
    
    echo -n "."
    sleep 5
done

if [ $DELETE_FOUND -eq 0 ]; then
    echo ""
    echo "Warning: Deletion not reflected in Athena after ${MAX_WAIT}s"
fi

# Cleanup
kill $SSM_PID 2>/dev/null || true

echo ""
echo "=== Smoke Test Summary ==="
echo "  Insert latency: ${LATENCY}s"
if [ $UPDATE_FOUND -eq 1 ]; then
    echo "  Update latency: ${UPDATE_LATENCY}s"
fi
if [ $DELETE_FOUND -eq 1 ]; then
    echo "  Delete latency: ${DELETE_LATENCY}s"
fi
echo ""

if [ $FOUND -eq 1 ] && [ $UPDATE_FOUND -eq 1 ] && [ $DELETE_FOUND -eq 1 ]; then
    echo "All tests passed!"
    exit 0
else
    echo "Some tests failed or timed out"
    exit 1
fi
