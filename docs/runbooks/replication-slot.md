# Replication Slot Management Runbook

This runbook covers monitoring and managing Debezium's PostgreSQL replication slot, understanding WAL growth risks, and cleanup procedures.

## Overview

Debezium creates a **logical replication slot** named `debezium_slot` in RDS Postgres. This slot:
- Tracks the position of the CDC consumer in the Write-Ahead Log (WAL)
- Ensures WAL segments are retained until Debezium consumes them
- Prevents WAL data loss if Debezium temporarily stops

**Risk**: If Debezium stops consuming (connector failure, network issue, etc.), the slot **holds WAL segments indefinitely**, which can fill disk storage.

## Monitoring Replication Slots

### Check Slot Status

Connect to RDS and query:

```sql
SELECT 
  slot_name,
  active,
  restart_lsn,
  confirmed_flush_lsn,
  pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS lag
FROM pg_replication_slots;
```

**Columns**:
- `slot_name`: `debezium_slot`
- `active`: `t` (true) if Debezium is connected, `f` (false) if not
- `restart_lsn`: WAL position the slot is holding
- `confirmed_flush_lsn`: Last position confirmed by Debezium
- `lag`: Amount of WAL data held (if large, indicates the connector is behind or stopped)

### Acceptable Lag

- **< 100 MB**: Normal (connector is keeping up)
- **100 MB - 1 GB**: Connector may be behind; check connector logs
- **> 1 GB**: High risk of storage exhaustion; investigate immediately

### Connect to RDS

Use the bastion:

```bash
cd terraform
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

psql -h localhost -p 5433 -U "$RDS_USER" -d "$RDS_DB"
cd ..
```

Run the query above in the `psql` session.

## Understanding WAL Growth

### Why WAL Grows

Postgres writes all changes to the WAL before committing. The WAL is normally recycled after:
- Checkpoints complete
- WAL segments are archived (if archiving is enabled)
- **Replication slots consume them**

If a replication slot is **inactive** (Debezium stopped), Postgres:
- Keeps all WAL segments since the slot's `restart_lsn`
- Cannot recycle them
- Continues writing new WAL segments

**Result**: WAL directory grows until:
- Debezium resumes and consumes the WAL
- You manually drop the slot
- RDS storage fills (causes downtime)

### Check WAL Usage

In RDS CloudWatch:
- Metric: `TransactionLogsDiskUsage` (namespace: `AWS/RDS`)
- Alert if > 5 GB or > 50% of allocated storage

In Postgres:

```sql
SELECT pg_size_pretty(sum(size)) AS wal_size
FROM pg_ls_waldir();
```

## Debezium Connector Failure Scenarios

### Scenario 1: Connector Stops, Then Restarts

- Slot remains active, holds WAL
- Debezium resumes, consumes backlog
- WAL is recycled after consumption
- **Action**: Monitor lag, ensure connector restarts within retention window

### Scenario 2: Connector Deleted, Slot Remains

- Slot becomes inactive
- WAL grows indefinitely
- **Action**: Drop the slot manually (see below)

### Scenario 3: Network Partition

- Slot appears active to Postgres, but Debezium isn't consuming
- WAL grows
- **Action**: Check `confirmed_flush_lsn` (if not advancing, the connection is stalled)

## Dropping the Replication Slot

### When to Drop

- Debezium connector is permanently deleted
- You're decommissioning the CDC pipeline
- WAL growth is critical and you're willing to lose CDC position (requires resnapshot)

### Procedure

```sql
-- Stop Debezium connector first (to prevent it from recreating the slot)

-- Drop the slot
SELECT pg_drop_replication_slot('debezium_slot');
```

**Warning**: Dropping the slot **loses the CDC position**. When you restart Debezium:
- It creates a new slot
- It performs a **full snapshot** of all tables (not incremental)
- This can take a long time for large databases

### Verify Slot is Dropped

```sql
SELECT * FROM pg_replication_slots;
```

Should return no rows (or no row for `debezium_slot`).

## Preventing WAL Growth

### 1. Monitor Connector State

Set up a CloudWatch Alarm for MSK Connect connector state:

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name "cdc-lakehouse-debezium-connector-down" \
  --metric-name "ConnectorStatus" \
  --namespace "AWS/KafkaConnect" \
  --statistic "Average" \
  --period 300 \
  --threshold 1 \
  --comparison-operator "LessThanThreshold" \
  --evaluation-periods 2 \
  --alarm-actions <SNS_TOPIC_ARN>
```

### 2. Set Replication Slot Limits

In the RDS parameter group, set:

```hcl
parameter {
  name  = "max_slot_wal_keep_size"
  value = "10240"  # 10 GB
}
```

If WAL exceeds this, Postgres **drops the slot** (requires Postgres 13+). This prevents storage exhaustion but causes Debezium to lose position.

### 3. Increase RDS Storage

Temporary measure: increase allocated storage to accommodate WAL growth while you fix the connector.

### 4. Alert on WAL Growth

CloudWatch Alarm for `TransactionLogsDiskUsage`:

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name "cdc-lakehouse-rds-wal-growth" \
  --metric-name "TransactionLogsDiskUsage" \
  --namespace "AWS/RDS" \
  --statistic "Average" \
  --period 300 \
  --threshold 5000000000 \
  --comparison-operator "GreaterThanThreshold" \
  --evaluation-periods 1 \
  --alarm-actions <SNS_TOPIC_ARN> \
  --dimensions Name=DBInstanceIdentifier,Value=<RDS_INSTANCE_ID>
```

## Cleanup After Connector Deletion

If you've run `terraform destroy` or manually deleted the Debezium connector:

1. Connect to RDS (if RDS still exists)
2. Drop the replication slot:

```sql
SELECT pg_drop_replication_slot('debezium_slot');
```

3. Verify WAL is recycled:

```sql
SELECT pg_size_pretty(sum(size)) AS wal_size
FROM pg_ls_waldir();
```

WAL size should decrease after the next checkpoint.

## RDS Deletion Behavior

When you delete an RDS instance:
- All replication slots are automatically deleted
- WAL data is deleted
- No manual cleanup needed

## Production Recommendations

1. **Monitor replication lag**: Alert if `pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn) > 1GB`
2. **Monitor connector state**: Alert if connector is not `RUNNING`
3. **Set `max_slot_wal_keep_size`**: Protect against unbounded WAL growth (Postgres 13+)
4. **Automate slot cleanup**: If connector is down for > N minutes, drop the slot and resnapshot
5. **Use Multi-AZ RDS**: Replication slots are replicated to standby (high availability)

## Summary

Replication slots are **critical for CDC correctness** but can cause **storage exhaustion** if not monitored. Key points:

- **Active slots hold WAL**: If Debezium stops, WAL grows
- **Monitor lag and connector state**: Alert on high lag or inactive slots
- **Drop slots when decommissioning**: Avoid leaving orphaned slots
- **Set `max_slot_wal_keep_size`**: Protection against runaway growth (Postgres 13+)
- **RDS deletion cleans up slots**: No manual action needed after `terraform destroy`

For this starter, RDS is deleted during `make destroy`, so slots are automatically cleaned up. For production, implement monitoring and alerting.
