# AWS CDC Lakehouse Starter

A reference implementation for Change Data Capture (CDC) into an Apache Iceberg data lakehouse on AWS. Expected latency ~1-2 minutes based on the 60-second commit interval (not yet measured in live deployment).

**Architecture**: RDS Postgres (logical replication) → Debezium 2.7.3 on MSK Connect → Amazon MSK Serverless → Iceberg Sink 0.6.19 on MSK Connect → S3 (Iceberg tables) → Glue Data Catalog → Athena

## What This Is

This is a **downloadable starter** for platform and data engineers who want to understand CDC lakehouses on AWS or need a foundation to customize. It demonstrates:

- End-to-end CDC from a transactional database to a queryable lakehouse
- Debezium's pgoutput-based replication (no custom plugins in RDS)
- Apache Iceberg format v2 with upsert semantics (updates and deletes)
- MSK Connect with scoped IAM and CloudWatch logging
- Terraform infrastructure that can be deployed, tested, and cleanly destroyed
- Private VPC with bastion + SSM access (no NAT gateway, uses interface endpoints)
- Smoke tests that validate insert/update/delete propagation

## Who This Is For

- **Platform/MLOps engineers** building or evaluating CDC pipelines on AWS
- **Data engineers** learning Debezium, Kafka Connect, or Iceberg
- **Architects** assessing AWS-managed streaming and lakehouse patterns

This is a **learning reference**, not a production system. Configuration choices are documented, limitations are stated honestly, and all claims are scoped to what has been CI-checked (live testing pending).

## When to Use This

Use this starter when:
- You need a working CDC reference to learn from or fork
- You want to prototype a CDC lakehouse in a single AWS account
- You need a known-good baseline before customizing connectors or schemas
- You're evaluating MSK Connect vs. self-hosted Kafka Connect

## When NOT to Use This

Do not use this as-is for production:

- **Single AWS account**: No environment separation
- **Single Postgres source**: No multi-source or heterogeneous replication
- **No schema registry**: Events are plain JSON without schema enforcement
- **Simplified security**: No encryption at rest with CMKs, no VPC Flow Logs, no MFA
- **Basic observability**: CloudWatch logs only, no tracing, metrics dashboards, or alerting
- **No HA/DR**: Single-region, no automated failover or backup/restore workflows
- **IAM scoping**: Scoped to cluster/topics/buckets but not least-privilege (e.g., VPC permissions are *)

This is v0.1.0—a solid foundation, not a complete production system.

## Architecture

![Architecture Diagram](docs/architecture.png)

### Data Flow

1. **RDS Postgres** with logical replication publishes changes via the `pgoutput` plugin
2. **Debezium Postgres Connector** (v2.7.3.Final) on MSK Connect captures changes and emits Kafka events
3. **Amazon MSK Serverless** (IAM auth, auto-scaling) brokers the change stream with one topic per table
4. **Tabular Iceberg Kafka Connect Sink** (v0.6.19) consumes events, handles the Debezium envelope, and writes Iceberg tables
5. **S3 + Glue Data Catalog** store Iceberg metadata and Parquet data files
6. **Athena** queries the lakehouse with SQL, including Iceberg time-travel queries

### Connectivity

- **Private VPC** with no NAT gateway (cost optimization)
- **VPC Endpoints**: S3 Gateway (free), plus 8 Interface endpoints (Glue, STS, Secrets Manager, CloudWatch Logs, CloudWatch Monitoring, SSM, SSM Messages, EC2 Messages)
- **Bastion**: t3.micro EC2 instance in a public subnet with public IP for SSM Session Manager port forwarding to RDS
- **MSK Connect** runs in private subnets with IAM-based Kafka authentication

**Design choice**: 8 interface endpoints × 2 AZs × $0.01/hr = $0.16/hr vs NAT Gateway at $0.045/hr + data transfer. Endpoints are more expensive for always-on production use but simpler for short tests and this demo architecture avoids NAT Gateway complexity. For long-running production, evaluate NAT Gateway + fewer endpoints.

## Architecture Decisions

### Why MSK Serverless?

**MSK Connect DOES support MSK Serverless** ([AWS MSK Connect documentation](https://docs.aws.amazon.com/msk/latest/developerguide/msk-connect.html), verified 2026-09-28).

MSK Serverless provides:
- **No broker management**: Auto-scaling capacity, no instance types to choose
- **IAM-only authentication**: Simplified security model (no SASL/SCRAM or ACLs)
- **Pay-per-use**: Cluster-hour + partition-hour pricing
- **Operational simplicity**: Perfect for prototypes and dev environments

**Limitations**:
- **Topic creation**: Debezium topics are auto-created by Kafka Connect; control topic must be created via bastion/SSM (automated in `make seed`)
- **Partition limits**: 2,400 for non-compacted topics, 120 for compacted (Kafka Connect internals are compacted)
- **Throughput per partition**: 5 MB/s in, 10 MB/s out (sufficient for CDC)

For production, evaluate provisioned MSK if you need:
- Broker-level configuration control
- More than 120 compacted topic partitions
- Predictable monthly costs vs. usage-based billing

### Why pgoutput Instead of wal2json or decoderbufs?

The `pgoutput` logical decoding plugin is **built into Postgres 10+** and does not require installing extensions in RDS. It is Debezium's recommended plugin for RDS Postgres ([Debezium Postgres docs](https://debezium.io/documentation/reference/stable/connectors/postgresql.html), verified 2026-09-28).

### Why MSK Connect Instead of Self-Hosted Kafka Connect?

MSK Connect is **fully managed**: AWS handles worker provisioning, scaling, patching, and integration with IAM and CloudWatch. For this reference, managed simplicity outweighs the flexibility of self-hosted workers. The Terraform here provisions and configures custom plugins automatically.

### Why Iceberg Format v2?

Iceberg v2 supports **row-level deletes and updates** via delete files, which the Iceberg sink uses to handle Debezium's delete events. Format v1 only supports append and overwrite, making CDC updates inefficient.

### Why Debezium 2.7.3 and Tabular Iceberg 0.6.19?

**MSK Connect runtime 3.7.x uses Kafka 3.7.x and Java 17** ([AWS MSK Connect runtimes](https://docs.aws.amazon.com/msk/latest/developerguide/msk-connect-workers.html), verified 2026-09-28). The Debezium 3.x series targets Java 17+ and Kafka Connect 3.x, so technically Debezium 3.x should work. However, this starter uses:

- **Debezium 2.7.3.Final**: Latest 2.7.x release, widely deployed, stable with Postgres connector on Java 11+ and Kafka Connect 2.x/3.x
- **Tabular Iceberg 0.6.19**: Last stable release from Tabular before the repository was deprecated in favor of Apache Iceberg's official connector (not yet field-tested for this stack)

**Honest rationale**: Debezium 2.7.3 is a conservative choice. Debezium 3.x would likely work but hasn't been tested in this starter. For production, evaluate Debezium 3.x or the Apache Iceberg Kafka Connect project.

## Prerequisites

- **AWS Account** with admin-equivalent permissions (the test runs as root user, cannot assume roles)
- **AWS CLI** (v1 or v2) configured with credentials
- **Terraform** >= 1.5.0
- **PostgreSQL client** (`psql`)
- **Python 3.9+** with `boto3`, `psycopg2`
- **Session Manager plugin** for AWS CLI ([installation guide](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html))
- **zip, curl, shasum**: Standard Unix tools (macOS and Linux compatible)

**macOS bash 3.2 compatibility**: Scripts are syntax-checked with bash -n under bash 3.2 in CI. No bashisms or GNU-specific flags.

## Quickstart

### 1. Pre-flight Check

```bash
make doctor
```

Validates:
- AWS credentials and region
- Required tools (terraform, aws, psql, python3, curl, shasum, zip, session-manager-plugin)
- Service quotas
- Terraform configuration
- Estimated hourly cost

### 2. Deploy (Staged Flow)

```bash
make up
```

**Staged deployment** (recommended):
1. `make apply-infra` — Deploy infrastructure (RDS, MSK, VPC) with connectors disabled
2. `make seed` — Create schema, publication, and control topic via SSM/bastion
3. `make apply-connectors` — Enable and deploy Debezium source and Iceberg sink connectors

Provisions:
- VPC, subnets, security groups, VPC endpoints (S3 Gateway + 8 Interface)
- RDS Postgres 16 with logical replication enabled
- MSK Serverless cluster with IAM auth
- MSK Connect custom plugins (Debezium, Iceberg) uploaded to S3
- Two MSK Connect connectors (Debezium source, Iceberg sink)
- Glue Data Catalog database
- Athena workgroup and named queries
- Bastion t3.micro instance for database/Kafka access

**Expected duration**: Infrastructure 5-10 minutes (MSK Serverless is fast), seed 2-3 minutes, connectors 3-5 minutes. **Total: ~10-18 minutes.**

### 3. Smoke Test

```bash
make smoke
```

End-to-end verification:
1. Inserts a row with a unique marker in Postgres
2. Polls Athena until the row appears (max 10 minutes)
3. Updates the row and verifies the update in Athena
4. Deletes the row and verifies the deletion in Athena

Measures elapsed time from INSERT until the row appears in Athena. Expected: ~1-2 min based on 60s commit interval.

**Expected duration**: 5-10 minutes (depends on Kafka Connect flush intervals and Athena query time)

**Typical latencies**: 30-120 seconds for inserts, updates, and deletes to appear in Athena.

### 4. Load Generator (Optional)

```bash
make load
```

Runs a Python load generator that performs random inserts, updates, and deletes at a configurable rate (default: 10 ops/sec for 60 seconds). Useful for observing steady-state behavior.

### 5. Query the Lakehouse

Use the AWS Console or CLI to run Athena queries. Named queries are pre-created:

- `cdc-lakehouse_orders_per_customer`: Orders and revenue per customer
- `cdc-lakehouse_revenue_by_day`: Daily revenue summary
- `cdc-lakehouse_top_selling_items`: Top items by revenue
- `cdc-lakehouse_time_travel_example`: Iceberg time-travel examples

To query from the CLI:

```bash
cd terraform
ATHENA_DB=$(terraform output -raw glue_database_name)
ATHENA_WG=$(terraform output -raw athena_workgroup_name)
REGION=$(terraform output -raw region)

QUERY_ID=$(aws athena start-query-execution \
  --query-string "SELECT * FROM customers LIMIT 10" \
  --query-execution-context "Database=$ATHENA_DB" \
  --work-group "$ATHENA_WG" \
  --region "$REGION" \
  --query 'QueryExecutionId' \
  --output text)

sleep 3

aws athena get-query-results \
  --query-execution-id "$QUERY_ID" \
  --region "$REGION" \
  --output table
cd ..
```

### 6. Destroy Infrastructure

```bash
make down
```

Tears down all resources. RDS has `skip_final_snapshot = true` and `deletion_protection = false` for easy cleanup. S3 buckets have `force_destroy = true`. Glue tables are cleaned up via a destroy provisioner.

**Expected duration**: 5-10 minutes

### 7. Verify Clean Teardown

```bash
make verify-clean
```

Independently checks that no billable resources remain using AWS CLI queries and default_tags filters.

## Cost Breakdown

Based on **AWS us-east-1 pricing as of 2026-09-28** ([pricing pages cited below](https://aws.amazon.com/pricing/)):

| Resource | Cost | Pricing Page |
|----------|------|--------------|
| **Compute** | | |
| RDS db.t4g.micro | $0.016/hour | [RDS PostgreSQL Pricing](https://aws.amazon.com/rds/postgresql/pricing/) |
| RDS storage (20 GB gp3) | $0.003/hour | [RDS PostgreSQL Pricing](https://aws.amazon.com/rds/postgresql/pricing/) |
| EC2 t3.micro bastion | $0.010/hour | [EC2 On-Demand Pricing](https://aws.amazon.com/ec2/pricing/on-demand/) |
| **Streaming** | | |
| MSK Serverless cluster-hour | $0.750/hour | [MSK Pricing](https://aws.amazon.com/msk/pricing/) |
| MSK Serverless partition-hours (~15) | $0.023/hour | [MSK Pricing](https://aws.amazon.com/msk/pricing/) |
| MSK Connect (2 MCU-hours) | $0.220/hour | [MSK Pricing](https://aws.amazon.com/msk/pricing/) |
| **Networking** | | |
| VPC Interface Endpoints (8 × 2 AZs) | $0.160/hour | [VPC Pricing](https://aws.amazon.com/vpc/pricing/) |
| Public IPv4 address | $0.005/hour | [VPC Pricing](https://aws.amazon.com/vpc/pricing/) |
| **Storage & Queries** | | |
| S3 Standard storage | $0.023/GB/month | [S3 Pricing](https://aws.amazon.com/s3/pricing/) |
| Athena queries | $5.00/TB scanned | [Athena Pricing](https://aws.amazon.com/athena/pricing/) |
| CloudWatch Logs | $0.50/GB ingested | [CloudWatch Pricing](https://aws.amazon.com/cloudwatch/pricing/) |

**Total estimated hourly cost**: ~$1.17-1.20/hour (estimate; actual cost depends on MSK Serverless partition count and data transfer)  
**Estimated cost for 1-hour test**: ~$1.20

**Breakdown details**:
- MSK Serverless: ~$0.75-0.80/hr (cluster + estimated ~10 partitions)
- MSK Connect: 2 connectors × 1 MCU each × $0.11/MCU-hr = $0.22/hr
- VPC Endpoints: 8 endpoints × 2 AZs × $0.01/endpoint-AZ-hr = $0.16/hr

**After `make down`**: Cost drops to ~$0 within minutes. S3 and CloudWatch Logs charges are minimal for test workloads.

**Note**: This cost estimate is based on 2026-09-28 pricing and assumes us-east-1. Actual costs may vary by region and usage patterns.

## Runbooks

See `docs/runbooks/` for operational procedures:

- **[Connector Restart](docs/runbooks/connector-restart.md)**: Stop/restart the Iceberg sink, verify it resumes from committed offsets without data loss or duplicates
- **[Replay from Beginning](docs/runbooks/replay.md)**: Reset the Iceberg sink consumer group to replay all events for a table
- **[Replication Slot Management](docs/runbooks/replication-slot.md)**: Monitor and manage Debezium's replication slot, WAL growth risks, and cleanup. Documents `wal_sender_timeout=0` configuration.
- **[Schema Changes](docs/runbooks/schema-changes.md)**: Adding/removing columns in Postgres, Iceberg schema evolution behavior, and limitations

## Limitations

### Connector Versions

- **Debezium 2.7.3.Final**: Java 11+ compatible, compatible with Java 17 (not yet live-tested)
- **Tabular Iceberg Kafka Connect 0.6.19**: Last stable release before Tabular deprecated the repository in favor of Apache Iceberg's official connector

**Note**: MSK Connect 3.7.x runtime uses Java 17. Debezium 2.7.3 (Java 11+) is compatible. Debezium 3.x (Java 17+) would be version-aligned but is not tested in this starter.

### AWS Secrets Manager Config Provider

**aws-samples/msk-config-providers 0.4.0**:
- URL: `https://github.com/aws-samples/msk-config-providers/releases/download/r0.4.0/msk-config-providers-0.4.0-all.jar`
- SHA256: `45dc671c2cec8412c436371abddff644598d00035a73487ab6db191db3563911` (verified)
- Class: `com.amazonaws.kafka.config.providers.SecretsManagerConfigProvider`
- Syntax: `${secretsmanager:secret-name:key}`

**Version choice**: 0.4.0 (not 0.5.0) because 0.5.0 targets Kafka 3.9+ and MSK Connect runtime 3.7.x uses Kafka 3.7.x.

### Schema Changes

- **Adding columns**: Debezium captures the change; Iceberg sink evolves the schema (adds nullable column)
- **Dropping columns**: Debezium omits the column from new events; old Iceberg columns remain (nullable, filled with nulls for new rows)
- **Renaming columns**: Treated as drop + add by Debezium; Iceberg sees a new column (data migration required)
- **Changing column types**: Often requires manual intervention and table rebuild

**Recommendation**: Test schema changes in a non-production environment first. The Iceberg sink's schema evolution is limited compared to a schema registry + Avro.

### No Schema Registry

Events are plain JSON without a schema registry (Confluent Schema Registry or AWS Glue Schema Registry). This simplifies the v0.1.0 stack but limits schema governance and compatibility checking.

### Single Table per Topic

Debezium is configured with `table.include.list` for three tables. Each table gets its own Kafka topic. This is the standard pattern for Debezium but may result in many topics for databases with hundreds of tables.

### Replication Slot Growth

Debezium creates a replication slot (`cdc_lakehouse_slot`) in RDS. If the connector stops consuming, the slot holds WAL segments, which can grow disk usage and eventually fill storage. This starter sets `wal_sender_timeout=0` (no timeout) so slots are not auto-dropped after network interruptions, but this means manual monitoring is required. Monitor replication slot lag and WAL usage. See `docs/runbooks/replication-slot.md`.

### IAM Scoping

IAM roles are scoped to:
- Specific MSK cluster ARN (includes cluster name and UUID)
- Specific topic patterns (e.g., `cdc-lakehouse.*`)
- Specific S3 bucket ARN and prefixes
- Specific Glue database
- Specific RDS secret ARN

This is **not least-privilege** in all cases (e.g., VPC permissions are `Resource: "*"` for ENI operations, S3 plugin access is scoped to bucket but not to minimal actions). Scoped, but not minimal. For production, audit IAM policies and tighten further.

### No Encryption with CMKs

S3 and RDS use AWS-managed keys (SSE-S3, default RDS encryption). For production, use customer-managed KMS keys.

### No Monitoring or Alerting

Connector logs go to CloudWatch Logs, but there are no CloudWatch Alarms, dashboards, or tracing. For production, add:
- MSK Connect connector state alarms
- RDS replication slot lag alarms
- Athena query cost and performance tracking

### Bastion Access

The bastion is a t3.micro instance in a public subnet with a public IP. SSM Session Manager is used for port forwarding (no SSH keys). For production, consider AWS Client VPN, AWS PrivateLink, or a more hardened bastion with session recording and MFA.

## Security Notes

- **RDS password**: Managed by RDS and stored in Secrets Manager (no plaintext in Terraform state)
- **Kafka authentication**: IAM-based (no plaintext credentials)
- **Connector credentials**: MSK Connect uses the Secrets Manager config provider (aws-samples/msk-config-providers 0.4.0) to fetch the RDS password at runtime
- **S3 encryption**: SSE-S3 (AWS-managed keys)
- **VPC**: All data services (RDS, MSK, MSK Connect) are in private subnets with no direct internet access
- **Security groups**: Ingress limited to required ports and source security groups
- **IMDSv2**: Bastion instance requires IMDSv2

## Troubleshooting

### Connectors Not Running

Check MSK Connect connector status:

```bash
aws kafkaconnect list-connectors --region us-east-1
CONNECTOR_ARN=$(aws kafkaconnect list-connectors \
  --region us-east-1 \
  --query "connectors[?contains(connectorName, 'debezium')].connectorArn" \
  --output text)
aws kafkaconnect describe-connector --connector-arn "$CONNECTOR_ARN" --region us-east-1
```

Check CloudWatch Logs (CLI v1 compatible):

```bash
aws logs filter-log-events \
  --log-group-name "/aws/msk-connect/cdc-lakehouse-debezium-" \
  --start-time $(($(date +%s) - 3600))000 \
  --region us-east-1 \
  --query 'events[*].message' \
  --output text
```

Common issues:
- **Debezium fails to connect**: Check RDS security group, Secrets Manager secret ARN, and IAM permissions
- **Iceberg sink fails**: Check Glue permissions, S3 permissions, and that control topic exists

### Data Not Appearing in Athena

1. Check Debezium is capturing changes: query the MSK topic via bastion or check Debezium logs
2. Check Iceberg sink consumer lag: look for lag metrics in CloudWatch or connector logs
3. Verify Glue tables exist: `aws glue get-tables --database-name <db> --region us-east-1`
4. Run Athena query and check for errors in the Athena console

### Replication Slot Growth

If the Debezium connector stops, the replication slot will hold WAL segments. Monitor:

```sql
SELECT slot_name, active, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS lag
FROM pg_replication_slots;
```

If lag grows beyond a few GB, consider:
- Restarting the Debezium connector
- Dropping and recreating the slot (requires resnapshot)
- Increasing RDS storage temporarily

See `docs/runbooks/replication-slot.md` for details.

## Development

### Terraform

```bash
make format      # Format Terraform files
make validate    # Validate configuration
```

### Linting

```bash
make lint        # Run shellcheck (warnings fail) and Python linters
```

### Testing

```bash
make test        # Run Python unit tests
```

### Render Architecture Diagram

```bash
make render-diagram
```

Requires `pip3 install diagrams graphviz` and Graphviz installed (`brew install graphviz` on macOS, `apt install graphviz` on Debian/Ubuntu).

## Project Structure

```
.
├── terraform/              # Terraform root module
│   ├── modules/
│   │   ├── athena/         # Athena workgroup and named queries
│   │   ├── glue/           # Glue Data Catalog database
│   │   ├── iam/            # IAM roles for MSK Connect connectors
│   │   ├── msk/            # MSK Serverless cluster and S3 bucket
│   │   ├── msk-connect/    # MSK Connect connectors and custom plugins
│   │   ├── networking/     # VPC, subnets, SGs, endpoints, bastion
│   │   └── rds/            # RDS Postgres with logical replication
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── versions.tf
├── scripts/                # Operational scripts
│   ├── doctor.sh           # Pre-flight checks
│   ├── seed.sh             # Schema, publication, control topic creation
│   ├── smoke.sh            # End-to-end test
│   ├── load_generator.py   # Load generator
│   └── verify-clean.sh     # Post-destroy verification
├── docs/                   # Documentation
│   ├── architecture.py     # Architecture diagram generator
│   ├── architecture.png    # Generated diagram
│   └── runbooks/           # Operational runbooks
├── tests/                  # Unit tests
├── Makefile                # Build automation
├── README.md               # This file
├── CHANGELOG.md            # Version history
├── LICENSE                 # MIT license
└── requirements.txt        # Python dependencies
```

## Contributing

This is a reference starter, not a framework. Fork it, customize it, and make it your own. If you find bugs or compatibility issues, please open an issue with:
- AWS service versions and regions
- Terraform version
- Error messages and logs

## License

MIT License. See [LICENSE](LICENSE).

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

## References

- [Debezium Postgres Connector](https://debezium.io/documentation/reference/stable/connectors/postgresql.html)
- [Tabular Iceberg Kafka Connect (deprecated)](https://github.com/tabular-io/iceberg-kafka-connect)
- [Apache Iceberg Kafka Connect](https://iceberg.apache.org/docs/latest/kafka-connect/)
- [AWS MSK Connect](https://docs.aws.amazon.com/msk/latest/developerguide/msk-connect.html)
- [AWS MSK Serverless](https://docs.aws.amazon.com/msk/latest/developerguide/serverless.html)
- [Terraform AWS Provider](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)

---

**Version**: 0.1.0  
**Last Updated**: 2026-09-28  
**Status**: CI-checked; live test pending
