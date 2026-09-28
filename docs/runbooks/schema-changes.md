# Schema Changes Runbook

This runbook covers how schema changes in RDS Postgres propagate through the CDC pipeline and the limitations you'll encounter.

## Overview

When you modify a table schema in Postgres:
1. Debezium captures the DDL change (if configured) or observes the new schema in subsequent DML events
2. Debezium emits events with the new schema
3. The Iceberg sink attempts to evolve the Iceberg table schema

The Iceberg Kafka Connect sink has **limited schema evolution** compared to a full schema registry setup.

## Adding a Column

### Procedure

1. Connect to RDS via the bastion:

```bash
cd terraform
BASTION_ID=$(terraform output -raw bastion_instance_id)
RDS_ENDPOINT=$(terraform output -raw rds_endpoint | cut -d: -f1)
RDS_PORT=$(terraform output -raw rds_port)
RDS_DB=$(terraform output -raw rds_database_name)
RDS_USER=$(terraform output -raw rds_master_username)
SECRET_ARN=$(terraform output -raw rds_secret_arn)
cd ..

# Get password
export PGPASSWORD=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" --query SecretString --output text | grep -o '"password":"[^"]*' | cut -d'"' -f4)

# Start tunnel
aws ssm start-session \
  --target "$BASTION_ID" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"$RDS_ENDPOINT\"],\"portNumber\":[\"$RDS_PORT\"],\"localPortNumber\":[\"5433\"]}" &
SSM_PID=$!

# Wait for tunnel
sleep 5
```

2. Add a column:

```bash
psql -h localhost -p 5433 -U "$RDS_USER" -d "$RDS_DB" -c \
  "ALTER TABLE public.customers ADD COLUMN phone VARCHAR(20);"
```

3. Insert a row with the new column:

```bash
psql -h localhost -p 5433 -U "$RDS_USER" -d "$RDS_DB" -c \
  "INSERT INTO public.customers (name, email, phone) VALUES ('Test User', 'test@example.com', '+1234567890');"
```

4. Verify in Athena (after a few minutes):

```bash
aws athena start-query-execution \
  --query-string "SELECT * FROM customers WHERE email = 'test@example.com'" \
  --query-execution-context "Database=cdc-lakehouse_lakehouse" \
  --work-group "cdc-lakehouse-workgroup" \
  --region us-east-1
```

5. Cleanup:

```bash
kill $SSM_PID
```

### Expected Behavior

- Debezium captures the new column in subsequent events
- The Iceberg sink **adds the column** to the Iceberg table as a **nullable column**
- Old rows will have `NULL` for the new column unless you backfill

### Limitations

- The new column is **always nullable**, even if you declared it `NOT NULL` in Postgres
- Default values from Postgres are **not** automatically backfilled in existing Iceberg rows

## Dropping a Column

### Procedure

```bash
psql -h localhost -p 5433 -U "$RDS_USER" -d "$RDS_DB" -c \
  "ALTER TABLE public.customers DROP COLUMN phone;"
```

### Expected Behavior

- Debezium **omits** the dropped column from new events
- The Iceberg table **retains** the column
- New rows written after the drop will have `NULL` for the dropped column in Iceberg

### Limitations

- **No automatic column deletion** in Iceberg
- You must manually drop the column in Iceberg if you want it removed from the schema
- Old data for the dropped column remains in Parquet files until rewritten

## Renaming a Column

### Procedure

```bash
psql -h localhost -p 5433 -U "$RDS_USER" -d "$RDS_DB" -c \
  "ALTER TABLE public.customers RENAME COLUMN phone TO mobile_phone;"
```

### Expected Behavior

- Debezium treats this as a **drop + add**
- The Iceberg sink sees a **new column** (`mobile_phone`) and keeps the old column (`phone`)
- Data is **not** automatically migrated from the old column to the new column

### Workaround

If you need to rename a column:

1. Add the new column
2. Backfill data: `UPDATE customers SET mobile_phone = phone;`
3. Wait for backfill to propagate via CDC
4. Drop the old column
5. Manually drop the old column in Iceberg if needed

## Changing Column Types

### Procedure

Not recommended without testing. Examples:

- `VARCHAR(50)` → `VARCHAR(100)`: Usually safe (widening)
- `VARCHAR(50)` → `TEXT`: May work if Iceberg maps both to `string`
- `INT` → `BIGINT`: Risky, may cause schema mismatch errors
- `VARCHAR` → `INT`: Will fail (incompatible types)

### Expected Behavior

- Debezium emits events with the new type
- Iceberg sink may **reject** the event if the type is incompatible
- You may need to:
  1. Stop the Iceberg sink
  2. Create a new Iceberg table with the new schema
  3. Replay events from the beginning to the new table
  4. Switch applications to the new table

## Monitoring Schema Changes

Check Iceberg sink logs for schema evolution errors:

```bash
aws logs filter-log-events \
  --log-group-name /aws/msk-connect/cdc-lakehouse-iceberg- \
  --filter-pattern "schema" \
  --start-time $(($(date +%s) - 3600))000 \
  --region us-east-1 | grep -i schema
```

Look for:
- `SchemaEvolutionException`
- `IncompatibleSchemaException`
- `Failed to evolve schema`

## Best Practices

1. **Test in non-prod first**: Always test schema changes in a separate environment
2. **Avoid renaming columns**: Use add + backfill + drop instead
3. **Avoid type changes**: If necessary, create a new table and migrate
4. **Document limitations**: Communicate to users that Iceberg schema != Postgres schema after changes
5. **Monitor connector logs**: Watch for schema evolution failures after DDL

## When to Rebuild Tables

If schema drift becomes unmanageable:

1. Stop the Iceberg sink connector
2. Drop the Iceberg table (or create a new one with a different name)
3. Reset the Iceberg sink consumer group to `earliest` (see `replay.md`)
4. Restart the connector to resnapshot and replay all events

## Alternative: Schema Registry

For production, consider:
- AWS Glue Schema Registry or Confluent Schema Registry
- Debezium with Avro serialization
- Iceberg sink with Avro support and schema registry integration

This provides:
- Centralized schema versioning
- Compatibility checks (backward, forward, full)
- Automatic schema evolution with rules

v0.1.0 uses plain JSON for simplicity, but schema registry is recommended for production.
