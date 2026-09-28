# Replay from Beginning Runbook

This runbook covers how to replay CDC events from the beginning to rebuild Iceberg tables.

## Overview

The Iceberg sink connector maintains consumer group offsets in Kafka. To replay events:
1. Stop the Iceberg sink connector
2. Delete the Iceberg tables (or create new ones with different names)
3. Reset the consumer group offsets to `earliest`
4. Restart the connector

The connector will re-consume all events from the Kafka topics and rebuild the Iceberg tables.

## Prerequisites

- `terraform` CLI
- AWS CLI configured
- Session Manager plugin installed
- psql client (for direct DB access, optional)

## Full Replay Runbook

### 1. Stop the Iceberg Sink Connector

```bash
cd terraform
CONNECTOR_ARN=$(terraform output -raw iceberg_connector_arn)
REGION=$(terraform output -raw region)

# Stop the connector
aws kafkaconnect delete-connector \
  --connector-arn "$CONNECTOR_ARN" \
  --region "$REGION"

# Wait for deletion (takes 5-10 minutes)
echo "Waiting for connector deletion..."
while true; do
  STATE=$(aws kafkaconnect describe-connector \
    --connector-arn "$CONNECTOR_ARN" \
    --region "$REGION" \
    --query 'connectorState' \
    --output text 2>/dev/null || echo "DELETED")
  echo "  Connector state: $STATE"
  [ "$STATE" = "DELETED" ] && break
  sleep 10
done
cd ..
```

### 2. Delete Iceberg Tables

Delete the tables via Athena:

```bash
cd terraform
DATABASE=$(terraform output -raw glue_database_name)
REGION=$(terraform output -raw region)
cd ..

# Delete each table
for table in customers orders order_items; do
  echo "Dropping $table..."
  aws athena start-query-execution \
    --query-string "DROP TABLE IF EXISTS ${DATABASE}.${table}" \
    --query-execution-context "Database=${DATABASE}" \
    --result-configuration "OutputLocation=s3://$(terraform output -raw s3_bucket_name)/athena-results/" \
    --region "$REGION"
done
```

Or connect via Athena console and run:
```sql
DROP TABLE IF EXISTS <database>.customers;
DROP TABLE IF EXISTS <database>.orders;
DROP TABLE IF EXISTS <database>.order_items;
```

### 3. Reset Consumer Group Offsets

The Iceberg sink connector uses:
- Consumer group: `cg-control-<connector-name>-<suffix>` for the control topic
- Internal Connect groups: `connect-<connector-name>-<suffix>`

**Important**: The bastion IAM role includes `DescribeGroup` and `AlterGroup` permissions for consumer offset management.

Find your actual group names:
```bash
cd terraform
MSK_CLUSTER_ARN=$(terraform output -raw msk_cluster_arn)
REGION=$(terraform output -raw region)
cd ..

# List consumer groups
aws kafka list-consumer-groups \
  --cluster-arn "$MSK_CLUSTER_ARN" \
  --region "$REGION" \
  --output json | jq '.consumerGroupSummaries[] | select(.consumerGroupName | contains("iceberg"))'
```

Reset via bastion using Kafka CLI:

```bash
cd terraform
BASTION_ID=$(terraform output -raw bastion_instance_id)
MSK_BOOTSTRAP=$(terraform output -raw msk_bootstrap_brokers)
REGION=$(terraform output -raw region)
cd ..

# SSH to bastion via SSM
aws ssm start-session --target "$BASTION_ID" --region "$REGION"

# On bastion:
cat > /tmp/client.properties <<'EOF'
security.protocol=SASL_SSL
sasl.mechanism=AWS_MSK_IAM
sasl.jaas.config=software.amazon.msk.auth.iam.IAMLoginModule required;
sasl.client.callback.handler.class=software.amazon.msk.auth.iam.IAMClientCallbackHandler
EOF

# Replace <ACTUAL-SUFFIX> with the connector suffix from list-consumer-groups
MSK_BOOTSTRAP="<bootstrap-servers>"

# Reset control group
/opt/kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server "$MSK_BOOTSTRAP" \
  --command-config /tmp/client.properties \
  --group cg-control-cdc-lakehouse-iceberg-sink-<ACTUAL-SUFFIX> \
  --reset-offsets \
  --to-earliest \
  --all-topics \
  --execute

# Reset connector group
/opt/kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server "$MSK_BOOTSTRAP" \
  --command-config /tmp/client.properties \
  --group connect-cdc-lakehouse-iceberg-sink-<ACTUAL-SUFFIX> \
  --reset-offsets \
  --to-earliest \
  --all-topics \
  --execute
```

Exit the SSM session.

### 4. Restart the Connector

Re-run the connector Terraform:

```bash
cd terraform
terraform apply -target=module.msk_connect.aws_mskconnect_connector.iceberg_sink
cd ..
```

Or recreate via `make apply-connectors`.

The connector will:
- Re-consume all events from the beginning of each topic
- Rebuild the Iceberg tables in Glue/S3
- Apply all insert/update/delete operations in order

### 5. Verify Replay

Check that the tables are recreated and data is arriving:

```bash
# Run smoke test
./scripts/smoke.sh
```

Or query via Athena:
```sql
SELECT COUNT(*) FROM <database>.customers;
SELECT COUNT(*) FROM <database>.orders;
SELECT COUNT(*) FROM <database>.order_items;
```

## Replay a Single Table

To replay only one table (e.g., `customers`):

### 1. Stop the Iceberg sink connector (same as above)

### 2. Delete only the target table

```sql
DROP TABLE IF EXISTS <database>.customers;
```

### 3. Reset consumer group offsets for that table's topic

On bastion:
```bash
# Reset to earliest for only the customers topic
/opt/kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server "$MSK_BOOTSTRAP" \
  --command-config /tmp/client.properties \
  --group cg-control-cdc-lakehouse-iceberg-sink-<ACTUAL-SUFFIX> \
  --topic cdc-lakehouse.public.customers \
  --reset-offsets \
  --to-earliest \
  --execute
```

### 4. Restart the connector

The connector will replay only the `customers` topic and rebuild only that table.

## Replay from a Specific Timestamp

To replay from a specific point in time (e.g., after a schema change):

```bash
# On bastion, use --to-datetime
/opt/kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server "$MSK_BOOTSTRAP" \
  --command-config /tmp/client.properties \
  --group cg-control-cdc-lakehouse-iceberg-sink-<ACTUAL-SUFFIX> \
  --reset-offsets \
  --to-datetime "2026-09-28T10:00:00.000" \
  --all-topics \
  --execute
```

Note: The timestamp must be in ISO 8601 format and in UTC.

## Troubleshooting

### Consumer group not found

If the consumer group doesn't exist yet, the connector will create it on first run. You can only reset offsets for groups that already exist.

### Topic ARN permissions

The bastion IAM role has `kafka-cluster:DescribeGroup` and `kafka-cluster:AlterGroup` on `group/<prefix>-*/*/*`. If you see authorization errors, check the IAM policy in `terraform/modules/networking/main.tf`.

### Connector stuck in CREATING

If the connector gets stuck during recreation, check CloudWatch logs:
```bash
aws logs tail /aws/msk-connect/cdc-lakehouse-iceberg-<suffix> \
  --follow \
  --region us-east-1
```

Common issues:
- Control topic doesn't exist (recreate via `scripts/seed.sh` if deleted)
- S3 bucket permissions
- Glue catalog permissions
- MSK cluster connectivity

## Related Runbooks

- [Replication Slot Management](replication-slot.md) - Managing the Debezium replication slot
- [Schema Changes](schema-changes.md) - Handling schema evolution
