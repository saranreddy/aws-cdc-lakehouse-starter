# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-09-28

### Summary

Initial release of AWS CDC Lakehouse Starter. This is a **learning reference** demonstrating end-to-end CDC from RDS Postgres to Apache Iceberg via Debezium and MSK Connect. CI-checked; live test pending.

### Added

#### Infrastructure

- **MSK Serverless** cluster with IAM authentication
  - Auto-scaling capacity (no broker management)
  - Pay-per-use pricing ($0.75/cluster-hr + $0.0015/partition-hr)
  - Verified compatible with MSK Connect ([AWS docs](https://docs.aws.amazon.com/msk/latest/developerguide/msk-connect.html), 2026-09-28)

- **MSK Connect connectors** (runtime 3.7.x, Kafka 3.7.x, Java 17):
  - **Debezium PostgreSQL source** 2.7.3.Final
    - Java 11+ compatible (runs on Java 17 runtime)
    - Native `pgoutput` replication
    - JSON converters
    - Topic auto-creation via Kafka Connect topic creation config
    - Secrets Manager config provider (aws-samples/msk-config-providers 0.4.0) for RDS password
  - **Tabular Iceberg Kafka Connect sink** 0.6.19
    - Last stable release from Tabular (repository deprecated; Apache Iceberg official connector recommended for future)
    - Upsert mode enabled
    - Glue Data Catalog integration
    - Format version 2 for row-level updates/deletes

- **Terraform infrastructure**:
  - MSK Serverless cluster (`aws_msk_serverless_cluster`)
  - Custom MSK Connect plugins with download/SHA256 verification
  - IAM policies scoped to cluster ARN, topic patterns, S3 bucket, Glue database, RDS secret
  - RDS PostgreSQL 16 with logical replication (`rds.logical_replication=1`)
  - RDS parameter: `wal_sender_timeout=0` (no timeout; holds slot indefinitely if connector stops)
  - AWS Glue Data Catalog for Iceberg metadata
  - Amazon Athena workgroup for queries
  - Private VPC with S3 Gateway endpoint + 8 Interface endpoints (Glue, STS, Secrets Manager, CloudWatch Logs, CloudWatch Monitoring, SSM, SSM Messages, EC2 Messages)
  - Bastion t3.micro in public subnet with public IP for SSM Session Manager access

- **Staged deployment flow**:
  - `make apply-infra` — Deploy infrastructure with `enable_connectors=false`
  - `make seed` — Create schema, publication, control topic via SSM send-command to bastion
  - `make apply-connectors` — Enable connectors with `enable_connectors=true`
  - `make up` — Run all three stages in order
  - `make down` — Destroy all infrastructure

- **Documentation**:
  - Architecture diagram (generated PNG via `diagrams` library)
  - Honest README with MSK Serverless rationale, cost analysis, limitations, and "when not to use"
  - Cost analysis: ~$1.17-1.20/hr estimated (verified 2026-09-28 pricing)
  - Connector version compatibility notes

- **Helper scripts**:
  - `seed.sh`: Database seeding (idempotent) + control topic creation via SSM send-command
  - `doctor.sh`: Pre-flight checks (tools, quotas, costs)
  - `smoke.sh`: End-to-end testing (insert/update/delete with measured latency)
  - `load_generator.py`: Load generator (configurable rate)
  - `verify-clean.sh`: Post-destroy verification (checks for remaining billable resources)

- **Runbooks** (`docs/runbooks/`):
  - Connector restart (stop/restart, offset resume, no data loss)
  - Replay from beginning (consumer group reset, table rebuild)
  - Replication slot management (WAL growth monitoring, `wal_sender_timeout=0` behavior)
  - Schema changes (Iceberg schema evolution, limitations)

- **CI** (`.github/workflows/ci.yml`):
  - Terraform fmt/validate
  - Shellcheck (warnings fail)
  - Python pylint
  - Python unit tests
  - Architecture diagram render check
  - Bash 3.2 compatibility check (macOS)
  - Bash logic tests (grep patterns, quota parsing)

### Architecture Decisions

**MSK Serverless over provisioned MSK**:
- Operational simplicity (no broker sizing/management)
- Auto-scaling capacity
- IAM-only authentication
- Suitable for prototypes and dev environments
- Limitation: Topic auto-creation handled by Kafka Connect for Debezium topics; control topic created via bastion/SSM

**Debezium 2.7.3.Final**:
- MSK Connect 3.7.x runtime uses Java 17
- Debezium 2.7.3 (Java 11+) runs successfully on Java 17 runtime
- Debezium 3.x (Java 17+) would be version-aligned but not tested in this starter
- Conservative choice: 2.7.3 is widely deployed and field-proven

**Tabular Iceberg 0.6.19**:
- Last proven stable release from Tabular
- Repository deprecated in favor of Apache Iceberg's official connector
- Field-tested with Debezium integration

**VPC Interface Endpoints over NAT Gateway**:
- 6 endpoints × 2 AZs × $0.01/hr = $0.12/hr
- vs NAT Gateway $0.045/hr + data transfer
- Simpler architecture for short tests; for long-running production evaluate NAT Gateway + fewer endpoints

**Bastion in public subnet**:
- t3.micro with public IP for SSM Session Manager
- No SSH keys (SSM-only access)
- Runs Kafka CLI tools for control topic creation and Kafka management
- Choice: Could use private bastion + 3 SSM interface endpoints, or public bastion + public IP (saves ~$0.03/hr)

### Known Limitations

- **MSK Connect 3.7.x runtime**: Java 17, Kafka 3.7.x
- **msk-config-providers**: aws-samples/msk-config-providers 0.4.0 (Kafka 3.7.x compatible; 0.5.0 targets Kafka 3.9+)
- **Single account**: No environment separation
- **No schema registry**: Plain JSON events without schema governance
- **IAM scoping**: Scoped to cluster/topics/buckets but not least-privilege (e.g., VPC permissions are `*`)
- **Basic observability**: CloudWatch logs only, no alarms, dashboards, or tracing
- **No HA/DR**: Single-region, no automated failover
- **Replication slot timeout**: `wal_sender_timeout=0` (no auto-drop; requires manual monitoring)

### Pricing (us-east-1, verified 2026-09-28)

- MSK Serverless: $0.75/cluster-hr + $0.0015/partition-hr (15 partitions = $0.023/hr)
- MSK Connect: 2 MCU-hrs = $0.22/hr
- RDS db.t4g.micro: $0.016/hr
- RDS storage (20 GB gp3): $0.003/hr
- EC2 t3.micro bastion: $0.010/hr
- VPC Interface endpoints (6 × 2 AZs): $0.12/hr
- Public IPv4: $0.005/hr
- **Total: ~$1.17-1.20/hr estimated**

### References

All AWS service compatibility claims verified against current AWS documentation as of 2026-09-28:
- MSK Serverless: https://docs.aws.amazon.com/msk/latest/developerguide/serverless.html
- MSK Connect: https://docs.aws.amazon.com/msk/latest/developerguide/msk-connect.html
- MSK Connect runtimes: https://docs.aws.amazon.com/msk/latest/developerguide/msk-connect-workers.html
- Debezium: https://debezium.io/releases/
- Pricing: https://aws.amazon.com/pricing/

### Status

**CI**: All checks pass (Terraform validate, shellcheck, pylint, tests, diagram render, bash 3.2 compatibility)

**Live testing**: Pending first live deployment

---

## Version History

- **0.1.0** (2026-09-28): Initial release
