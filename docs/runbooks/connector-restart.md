# Connector Restart Runbook

This runbook covers stopping and restarting the Iceberg sink connector and verifying that it resumes from committed offsets without data loss or duplicates.

## Overview

MSK Connect connectors maintain consumer group state in Kafka. When a connector stops (gracefully or due to failure) and restarts, it should resume from the last committed offset. This runbook demonstrates that behavior.

## Prerequisites

- Infrastructure deployed (`make apply`)
- Database seeded (`make seed`)
- At least a few events processed

## Procedure

### 1. Stop the Iceberg Sink Connector

```bash
cd terraform
ICEBERG_CONNECTOR_ARN=$(aws kafkaconnect list-connectors --region us-east-1 --query "connectors[?contains(connectorName, 'iceberg')].connectorArn" --output text)

aws kafkaconnect update-connector \
  --connector-arn "$ICEBERG_CONNECTOR_ARN" \
  --capacity "provisionedCapacity={mcuCount=1,workerCount=0}" \
  --region us-east-1
```

Wait for the connector to stop:

```bash
while true; do
  STATE=$(aws kafkaconnect describe-connector --connector-arn "$ICEBERG_CONNECTOR_ARN" --region us-east-1 --query 'connectorState' --output text)
  echo "State: $STATE"
  if [ "$STATE" = "FAILED" ]; then
    break
  fi
  sleep 10
done
```

Note: Setting `workerCount=0` stops the connector but MSK Connect may report it as `FAILED` rather than `STOPPED`. This is expected.

### 2. Insert Data While Connector is Stopped

Connect to RDS and insert a test row:

```bash
BASTION_ID=$(terraform output -raw bastion_instance_id)
RDS_ENDPOINT=$(terraform output -raw rds_endpoint | cut -d: -f1)
RDS_PORT=$(terraform output -raw rds_port)
RDS_DB=$(terraform output -raw rds_database_name)
RDS_USER=$(terraform output -raw rds_master_username)
SECRET_ARN=$(terraform output -raw rds_secret_arn)

export PGPASSWORD=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" --query SecretString --output text | grep -o '"password":"[^"]*' | cut -d'"' -f4)

aws ssm start-session \
  --target "$BASTION_ID" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"$RDS_ENDPOINT\"],\"portNumber\":[\"$RDS_PORT\"],\"localPortNumber\":[\"5433\"]}" &
SSM_PID=$!

sleep 5

MARKER="restart_test_$(date +%s)"
psql -h localhost -p 5433 -U "$RDS_USER" -d "$RDS_DB" -c \
  "INSERT INTO public.customers (name, email) VALUES ('Restart Test', '$MARKER@example.com');"

echo "Inserted customer with email: $MARKER@example.com"

kill $SSM_PID
cd ..
```

### 3. Verify Event is in Kafka Topic

The Debezium connector is still running, so the event should be in the Kafka topic. The Iceberg sink is stopped, so it's not yet written to Iceberg.

(Optional: Use a Kafka consumer to verify the topic has the event. This starter doesn't include Kafka client tools, but you can install `kafkacat` or use MSK Connect's built-in monitoring.)

### 4. Restart the Iceberg Sink Connector

```bash
cd terraform
aws kafkaconnect update-connector \
  --connector-arn "$ICEBERG_CONNECTOR_ARN" \
  --capacity "provisionedCapacity={mcuCount=1,workerCount=1}" \
  --region us-east-1
```

Wait for the connector to become `RUNNING`:

```bash
while true; do
  STATE=$(aws kafkaconnect describe-connector --connector-arn "$ICEBERG_CONNECTOR_ARN" --region us-east-1 --query 'connectorState' --output text)
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
MAX_WAIT=300
START=$(date +%s)

while [ $(($(date +%s) - START)) -lt $MAX_WAIT ]; do
  QUERY_ID=$(aws athena start-query-execution \
    --query-string "SELECT * FROM customers WHERE email = '$MARKER@example.com'" \
    --query-execution-context "Database=cdc-lakehouse_lakehouse" \
    --work-group "cdc-lakehouse-workgroup" \
    --region us-east-1 \
    --query 'QueryExecutionId' \
    --output text)
  
  sleep 3
  
  STATUS=$(aws athena get-query-execution \
    --query-execution-id "$QUERY_ID" \
    --region us-east-1 \
    --query 'QueryExecution.Status.State' \
    --output text)
  
  if [ "$STATUS" = "SUCCEEDED" ]; then
    RESULTS=$(aws athena get-query-results \
      --query-execution-id "$QUERY_ID" \
      --region us-east-1 \
      --output text | grep -c "$MARKER" || echo "0")
    
    if [ "$RESULTS" -gt 0 ]; then
      echo "Row found in Athena! Connector resumed successfully."
      exit 0
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
QUERY_ID=$(aws athena start-query-execution \
  --query-string "SELECT COUNT(*) FROM customers WHERE email = '$MARKER@example.com'" \
  --query-execution-context "Database=cdc-lakehouse_lakehouse" \
  --work-group "cdc-lakehouse-workgroup" \
  --region us-east-1 \
  --query 'QueryExecutionId' \
  --output text)

sleep 3

aws athena get-query-results \
  --query-execution-id "$QUERY_ID" \
  --region us-east-1 \
  --output table
```

Expected result: `1` row. If you see duplicates, the connector may have reprocessed events (check for consumer group reset or connector configuration issues).

## Expected Behavior

- The Iceberg sink maintains its consumer group offset in Kafka's internal `__consumer_offsets` topic
- When the connector stops gracefully, it commits offsets before shutting down
- When the connector restarts, it resumes from the last committed offset
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

Check connector logs for offset commits:

```bash
aws logs tail /aws/msk-connect/cdc-lakehouse-iceberg- --follow --region us-east-1 | grep -i "commit"
```

Look for:
- `Committing offsets`
- `Offset commit succeeded`
- `Rebalancing` (consumer group rebalance during restart)

## Summary

The Iceberg sink connector is **stateful** and resumes from committed offsets. In normal operation:
- **Data loss**: None (events are not skipped)
- **Duplicates**: Minimal (Iceberg upsert mode makes most operations idempotent)

For production:
- Monitor connector state with CloudWatch Alarms
- Set up alerting for connector failures
- Test restart behavior under load to understand recovery time
