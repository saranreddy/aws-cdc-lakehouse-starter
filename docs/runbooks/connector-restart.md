# Connector Restart Runbook

This runbook covers stopping and restarting the Iceberg sink connector and verifying that it resumes from committed offsets without data loss or duplicates.

## Overview

MSK Connect connectors maintain consumer group state in Kafka. When a connector stops (gracefully or due to failure) and restarts, it should resume from the last committed offset. This runbook demonstrates that behavior.

## Prerequisites

- Infrastructure deployed (`make up`)
- Database seeded (`make seed`)
- At least a few events processed

## Procedure

### 1. Stop the Iceberg Sink Connector

**Note**: MSK Connect autoscaling has a minimum worker count of 1. To stop processing without deleting the connector, you can:
- Pause the connector (if supported by your MSK Connect version)
- Or delete and recreate it (shown below)

```bash
cd terraform
ICEBERG_CONNECTOR_ARN=$(aws kafkaconnect list-connectors \
  --region us-east-1 \
  --query "connectors[?contains(connectorName, 'iceberg')].connectorArn" \
  --output text)

echo "Deleting connector to stop processing..."
aws kafkaconnect delete-connector \
  --connector-arn "$ICEBERG_CONNECTOR_ARN" \
  --region us-east-1

# Wait for deletion
while true; do
  STATE=$(aws kafkaconnect describe-connector \
    --connector-arn "$ICEBERG_CONNECTOR_ARN" \
    --region us-east-1 \
    --query 'connectorState' \
    --output text 2>&1 || echo "DELETED")
  echo "State: $STATE"
  if echo "$STATE" | grep -q "NotFoundException\|DELETED"; then
    echo "Connector deleted."
    break
  fi
  sleep 10
done
cd ..
```

### 2. Insert Data While Connector is Stopped

Connect to RDS and insert a test row:

```bash
cd terraform
BASTION_ID=$(terraform output -raw bastion_instance_id)
RDS_ENDPOINT=$(terraform output -raw rds_endpoint | cut -d: -f1)
RDS_PORT=$(terraform output -raw rds_port)
RDS_DB=$(terraform output -raw rds_database_name)
RDS_USER=$(terraform output -raw rds_master_username)
SECRET_ARN=$(terraform output -raw rds_secret_arn)
REGION=$(terraform output -raw region)

# Get password via python (CLI v1 compatible)
PGPASSWORD=$(aws secretsmanager get-secret-value \
  --secret-id "$SECRET_ARN" \
  --region "$REGION" \
  --query SecretString \
  --output text | python3 -c "import sys, json; print(json.loads(input())['password'])")
export PGPASSWORD

# Start SSM tunnel
aws ssm start-session \
  --target "$BASTION_ID" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"$RDS_ENDPOINT\"],\"portNumber\":[\"$RDS_PORT\"],\"localPortNumber\":[\"5433\"]}" \
  >/dev/null 2>&1 &
SSM_PID=$!

sleep 5

MARKER="restart_test_$(date +%s)"
psql -h localhost -p 5433 -U "$RDS_USER" -d "$RDS_DB" -c \
  "INSERT INTO public.customers (name, email) VALUES ('Restart Test', '$MARKER@example.com');"

echo "Inserted customer with email: $MARKER@example.com"

kill $SSM_PID 2>/dev/null || true
cd ..
```

### 3. Verify Event is in Kafka Topic

The Debezium connector is still running, so the event should be in the Kafka topic. The Iceberg sink is stopped, so it's not yet written to Iceberg.

To verify the topic has the event, you can check the Kafka topic from the bastion (which has Kafka CLI tools installed):

```bash
cd terraform
BASTION_ID=$(terraform output -raw bastion_instance_id)
MSK_BOOTSTRAP=$(terraform output -raw msk_bootstrap_brokers)
REGION=$(terraform output -raw region)

# Send command to bastion to check topic
COMMAND_ID=$(aws ssm send-command \
  --instance-ids "$BASTION_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters "commands=['
    /opt/kafka/bin/kafka-console-consumer.sh \
      --bootstrap-server $MSK_BOOTSTRAP \
      --command-config /tmp/client.properties \
      --topic cdc-lakehouse.public.customers \
      --from-beginning \
      --max-messages 10 | tail -5
  ']" \
  --region "$REGION" \
  --query 'Command.CommandId' \
  --output text)

# Wait and get output
sleep 10
aws ssm get-command-invocation \
  --command-id "$COMMAND_ID" \
  --instance-id "$BASTION_ID" \
  --region "$REGION" \
  --query 'StandardOutputContent' \
  --output text
cd ..
```

### 4. Restart the Iceberg Sink Connector

Recreate the connector using Terraform:

```bash
cd terraform
terraform apply -var='enable_connectors=true' -auto-approve
cd ..
```

Wait for the connector to become `RUNNING`:

```bash
cd terraform
ICEBERG_CONNECTOR_ARN=$(aws kafkaconnect list-connectors \
  --region us-east-1 \
  --query "connectors[?contains(connectorName, 'iceberg')].connectorArn" \
  --output text)

while true; do
  STATE=$(aws kafkaconnect describe-connector \
    --connector-arn "$ICEBERG_CONNECTOR_ARN" \
    --region us-east-1 \
    --query 'connectorState' \
    --output text 2>/dev/null || echo "CREATING")
  echo "State: $STATE"
  if [ "$STATE" = "RUNNING" ]; then
    echo "Connector restarted!"
    break
  fi
  sleep 10
done
cd ..
```

### 5. Verify the Event Appears in Athena

Poll Athena for the inserted row:

```bash
cd terraform
ATHENA_DB=$(terraform output -raw glue_database_name)
ATHENA_WG=$(terraform output -raw athena_workgroup_name)
REGION=$(terraform output -raw region)
cd ..

MAX_WAIT=600
START=$(date +%s)

while [ $(($(date +%s) - START)) -lt $MAX_WAIT ]; do
  QUERY_ID=$(aws athena start-query-execution \
    --query-string "SELECT * FROM customers WHERE email = '$MARKER@example.com'" \
    --query-execution-context "Database=$ATHENA_DB" \
    --work-group "$ATHENA_WG" \
    --region "$REGION" \
    --query 'QueryExecutionId' \
    --output text 2>/dev/null)
  
  if [ -n "$QUERY_ID" ]; then
    sleep 3
    
    STATUS=$(aws athena get-query-execution \
      --query-execution-id "$QUERY_ID" \
      --region "$REGION" \
      --query 'QueryExecution.Status.State' \
      --output text 2>/dev/null)
    
    if [ "$STATUS" = "SUCCEEDED" ]; then
      RESULTS=$(aws athena get-query-results \
        --query-execution-id "$QUERY_ID" \
        --region "$REGION" \
        --output text 2>/dev/null | grep -c "$MARKER" 2>/dev/null || echo "0")
      
      if [ "$RESULTS" -gt 0 ]; then
        echo "Row found in Athena! Connector resumed successfully."
        exit 0
      fi
    fi
  fi
  
  echo -n "."
  sleep 10
done

echo "Row not found after ${MAX_WAIT}s. Check connector logs."
exit 1
```

### 6. Verify No Duplicates

Run the same query and count rows:

```bash
cd terraform
ATHENA_DB=$(terraform output -raw glue_database_name)
ATHENA_WG=$(terraform output -raw athena_workgroup_name)
REGION=$(terraform output -raw region)

QUERY_ID=$(aws athena start-query-execution \
  --query-string "SELECT COUNT(*) FROM customers WHERE email = '$MARKER@example.com'" \
  --query-execution-context "Database=$ATHENA_DB" \
  --work-group "$ATHENA_WG" \
  --region "$REGION" \
  --query 'QueryExecutionId' \
  --output text)

sleep 5

aws athena get-query-results \
  --query-execution-id "$QUERY_ID" \
  --region "$REGION" \
  --output table
cd ..
```

Expected result: `1` row. If you see duplicates, the connector may have reprocessed events (check for consumer group reset or connector configuration issues).

## Expected Behavior

- The Iceberg sink maintains its consumer group offset in Kafka's internal `__consumer_offsets` topic
- Consumer group name: `connect-cdc-lakehouse-iceberg-<suffix>` (MSK Connect auto-generated)
- When the connector stops gracefully, it commits offsets before shutting down
- When the connector restarts (or is recreated), it attempts to resume from the last committed offset
- Events produced while the connector was down are processed after restart (catch-up)
- **No data loss**: All events are processed
- **No duplicates** (in the common case): Events are processed exactly once

## Failure Scenarios

### Connector Crashes Without Committing Offsets

If the connector crashes or is forcibly terminated:
- It may reprocess a small number of events (since the last commit)
- Iceberg's upsert mode means **updates and inserts are idempotent** (same row written twice = same result)
- **Deletes may be reprocessed**, but Debezium tombstone semantics should prevent incorrect resurrection

### Consumer Group Reset

If the consumer group is manually reset (see `replay.md`):
- The connector reprocesses all events from the reset point
- In upsert mode, this rebuilds the table to the current state
- Old data is overwritten (not duplicated)

## Monitoring

Check connector logs using AWS CLI v1 compatible commands:

```bash
cd terraform
REGION=$(terraform output -raw region)
cd ..

# Get recent log events (CLI v1 compatible)
aws logs filter-log-events \
  --log-group-name "/aws/msk-connect/cdc-lakehouse-iceberg-" \
  --start-time $(($(date +%s) - 3600)) \
  --region "$REGION" \
  --query 'events[*].message' \
  --output text | grep -i "commit"
```

Look for:
- `Committing offsets`
- `Offset commit succeeded`
- `Rebalancing` (consumer group rebalance during restart)

MSK Connect internal consumer groups (auto-created):
- `__amazon_msk_connect_<cluster-uuid>_<connector-name>-<version>` (offsets, config, status)
- `connect-<connector-name>` (sink connector consumer group)
- `cg-control-<connector-name>` (Iceberg control topic consumer group)

## Summary

The Iceberg sink connector is **stateful** and resumes from committed offsets. In normal operation:
- **Data loss**: None (events are not skipped)
- **Duplicates**: Minimal (Iceberg upsert mode makes most operations idempotent)

For production:
- Monitor connector state with CloudWatch Alarms
- Set up alerting for connector failures
- Test restart behavior under load to understand recovery time
