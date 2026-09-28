# Replay from Beginning Runbook

This runbook covers how to reset the Iceberg sink connector's consumer group to replay all events for a table from the beginning.

## Overview

The Iceberg sink connector maintains a consumer group offset in Kafka. To replay events:
1. Stop the connector
2. Delete the Iceberg table (or create a new one)
3. Reset the consumer group to `earliest`
4. Restart the connector

The connector will re-consume all events from the Kafka topics and rebuild the Iceberg table.

## When to Replay

Use replay when:
- You need to rebuild an Iceberg table from scratch (e.g., after schema changes)
- The table is corrupted or has incorrect data
- You want to reprocess events with a new connector configuration
- You're testing the pipeline end-to-end

## Prerequisites

- Infrastructure deployed
- At least one snapshot or set of CDC events in Kafka

## Procedure

### 1. Stop the Iceberg Sink Connector

```bash
cd terraform
ICEBERG_CONNECTOR_ARN=$(aws kafkaconnect list-connectors --region us-east-1 --query "connectors[?contains(connectorName, 'iceberg')].connectorArn" --output text)

echo "Stopping connector..."
aws kafkaconnect delete-connector \
  --connector-arn "$ICEBERG_CONNECTOR_ARN" \
  --region us-east-1

# Wait for deletion
while true; do
  STATE=$(aws kafkaconnect describe-connector --connector-arn "$ICEBERG_CONNECTOR_ARN" --region us-east-1 --query 'connectorState' --output text 2>&1)
  if echo "$STATE" | grep -q "NotFoundException"; then
    echo "Connector deleted."
    break
  fi
  echo "State: $STATE"
  sleep 10
done
```

**Warning**: `delete-connector` is permanent. You'll need to recreate the connector (via Terraform) after resetting offsets.

### 2. Delete the Iceberg Table (Optional)

If you want a fresh table:

```bash
GLUE_DB=$(terraform output -raw glue_database_name)
BUCKET=$(terraform output -raw s3_bucket_name)

# Drop Glue table
aws glue delete-table --database-name "$GLUE_DB" --name "customers" --region us-east-1 || true
aws glue delete-table --database-name "$GLUE_DB" --name "orders" --region us-east-1 || true
aws glue delete-table --database-name "$GLUE_DB" --name "order_items" --region us-east-1 || true

# Delete S3 data
aws s3 rm "s3://$BUCKET/iceberg/" --recursive
```

If you skip this step, replaying will overwrite existing data (upsert mode).

### 3. Reset Consumer Group Offsets

MSK Connect does not provide a built-in way to reset consumer group offsets. You need to use Kafka tools:

**Option A**: Use `kafka-consumer-groups.sh` from a Kafka client:

1. Launch a temporary EC2 instance in the VPC with Kafka tools installed
2. Download Kafka binaries (matching MSK version 3.5.1)
3. Configure IAM authentication for the Kafka client
4. Run:

```bash
kafka-consumer-groups.sh \
  --bootstrap-server <MSK_BOOTSTRAP_BROKERS> \
  --command-config client.properties \
  --group iceberg-sink-group \
  --reset-offsets \
  --to-earliest \
  --all-topics \
  --execute
```

**Option B**: Simplify by deleting and recreating the connector:

Since the connector is already deleted (step 1), Terraform will recreate it with a fresh consumer group. The connector configuration includes `consumer.auto.offset.reset=earliest`, so it will automatically start from the beginning if no offset is found.

### 4. Recreate the Iceberg Sink Connector

Run Terraform to recreate the connector:

```bash
terraform apply -auto-approve
cd ..
```

This recreates the MSK Connect connector. Since the consumer group was deleted (or has no offset), it starts from `earliest`.

### 5. Monitor the Replay

Check connector logs:

```bash
aws logs tail /aws/msk-connect/cdc-lakehouse-iceberg- --follow --region us-east-1
```

Look for:
- `Starting consumer group`
- `Resetting offset to earliest`
- `Processing records`
- Table creation in Glue

### 6. Verify Table is Rebuilt

Query Athena:

```bash
aws athena start-query-execution \
  --query-string "SELECT COUNT(*) FROM customers" \
  --query-execution-context "Database=cdc-lakehouse_lakehouse" \
  --work-group "cdc-lakehouse-workgroup" \
  --region us-east-1
```

The row count should match the number of distinct customers in Postgres (after upserts and deletes).

## How Long Does Replay Take?

Replay time depends on:
- Number of events in Kafka topics
- Kafka partition count (this starter uses 1 partition per topic)
- Iceberg sink throughput (1 MCU = ~100 MB/s)
- Number of tables

For the seed data (5 customers, 5 orders, 8 order items):
- Replay takes **1-3 minutes** (snapshot events + any updates)

For production with millions of events:
- Replay can take **hours**
- Consider increasing MCU count temporarily
- Monitor connector lag in CloudWatch

## Partial Replay (Single Table)

To replay only one table:

1. Stop the connector
2. Delete only the specific Iceberg table in Glue and S3
3. Reset offsets for only that table's topic:

```bash
kafka-consumer-groups.sh \
  --bootstrap-server <MSK_BOOTSTRAP_BROKERS> \
  --command-config client.properties \
  --group iceberg-sink-group \
  --reset-offsets \
  --to-earliest \
  --topic cdc-lakehouse.public.customers \
  --execute
```

4. Restart the connector

The connector will replay only the `customers` topic and rebuild only the `customers` Iceberg table.

## Replay from a Specific Timestamp

To replay from a specific point in time (e.g., after a schema change):

```bash
kafka-consumer-groups.sh \
  --bootstrap-server <MSK_BOOTSTRAP_BROKERS> \
  --command-config client.properties \
  --group iceberg-sink-group \
  --reset-offsets \
  --to-datetime "2026-09-28T10:00:00.000" \
  --all-topics \
  --execute
```

**Warning**: If the table schema changed, replaying from the middle may cause schema mismatch errors.

## Risks

- **Data inconsistency**: If you replay while Postgres continues to change, the final Iceberg state may not match Postgres (because you're replaying old events and then applying new ones)
- **Schema mismatch**: If the Postgres schema changed during the replay period, the connector may fail
- **Downtime**: While the connector is stopped, new CDC events are not written to Iceberg (they accumulate in Kafka)

## Best Practices

1. **Stop application writes** to the source tables during replay (if possible)
2. **Test replay in non-prod** first
3. **Monitor Kafka topic retention**: If events are older than the retention period (7 days by default in this starter), they are lost and cannot be replayed
4. **Snapshot first**: If you need to preserve the current Iceberg table, copy the S3 data and Glue metadata before deleting

## Alternative: Create a New Table

Instead of replaying to the same table, create a new Iceberg table with a different name:

1. Modify the Iceberg sink connector configuration to write to `customers_v2`, `orders_v2`, etc.
2. Reset consumer group to `earliest`
3. Restart the connector
4. Verify the new tables are correct
5. Switch applications to the new tables
6. Drop the old tables

This avoids downtime and allows rollback.

## Summary

Replaying from the beginning is a **destructive operation** that rebuilds Iceberg tables from Kafka topics. Use it when:
- The table is corrupted
- You need to apply schema changes retroactively
- You're testing the pipeline

For production, prefer incremental fixes (e.g., backfill specific rows) over full replay.
