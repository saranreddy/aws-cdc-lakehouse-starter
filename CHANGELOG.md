# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-09-28

### Added

- **MSK Serverless** cluster with IAM authentication
  - Auto-scaling capacity (no broker management)
  - Pay-per-use pricing ($0.75/cluster-hr + $0.0015/partition-hr)
  - Verified compatible with MSK Connect ([AWS docs](https://docs.aws.amazon.com/msk/latest/developerguide/msk-connect.html), 2026-09-28)

- **MSK Connect connectors** (runtime 3.7.1):
  - **Debezium PostgreSQL source** 2.7.3.Final
    - Java 11+ compatible
    - Native `pgoutput` replication
    - JSON converters
  - **Tabular Iceberg Kafka Connect sink** 0.6.19
    - Last stable release before Databricks archived project
    - Upsert mode enabled
    - Glue Data Catalog integration

- **Topic pre-creation script** (`scripts/create-topics.sh`)
  - Creates all required Kafka topics for MSK Serverless
  - 5 compacted topics (Kafka Connect internals + Debezium + Iceberg control)
  - 3 non-compacted CDC data topics
  - Integrated into seed workflow

- **Terraform infrastructure**:
  - MSK Serverless cluster (`aws_msk_serverless_cluster`)
  - Custom MSK Connect plugins with download/build logic
  - IAM policies with Serverless ARN patterns
  - RDS PostgreSQL 16 with logical replication
  - AWS Glue Data Catalog for Iceberg metadata
  - Amazon Athena workgroup for queries
  - Private VPC with S3 Gateway + Interface VPC Endpoints

- **Documentation**:
  - Architecture diagram (generated PNG)
  - Complete README with MSK Serverless rationale
  - Cost analysis ($1.14/hr, verified 2026-09-28)
  - Connector version compatibility justification

- **Helper scripts**:
  - `create-topics.sh`: Kafka topic creation
  - `seed.sh`: Database seeding (integrated with topic creation)
  - `doctor.sh`: Infrastructure health checks
  - `smoke.sh`: End-to-end testing
  - `verify-clean.sh`: Cleanup verification

### Architecture Decisions

**MSK Serverless over provisioned MSK**:
- Operational simplicity (no broker sizing/management)
- Auto-scaling capacity
- IAM-only authentication
- Suitable for prototypes and dev environments
- Limitation: No auto-topic creation (handled by `create-topics.sh`)

**Debezium 2.7.3.Final over 3.x**:
- MSK Connect 3.7.1 runtime uses Java 11
- Debezium 3.x requires Java 17+
- 2.7.3.Final is latest 2.7.x series with Java 11+ support

**Tabular Iceberg 0.6.19**:
- Last proven stable release
- Field-tested with Debezium integration
- Alternative: Apache Iceberg built-in (requires build from source)

### Known Limitations

- **MSK Serverless partition limits**: 2,400 non-compacted, 120 compacted
- **No auto-topic creation**: Topics must be explicitly created
- **Compacted topic limit**: Affects Kafka Connect internals (offsets, configs, status)
- **Single account**: No multi-account or environment separation
- **No schema registry**: Plain JSON events without schema governance
- **Basic observability**: CloudWatch logs only, no tracing or alerting

### Pricing (us-east-1, verified 2026-09-28)

- MSK Serverless: $0.75/cluster-hr + $0.0015/partition-hr
- MSK Connect: $0.11/MCU-hr (2 MCU = $0.22/hr)
- RDS db.t4g.micro: $0.016/hr
- Interface endpoints: $0.01/AZ-hr (6 endpoints × 2 AZs = $0.12/hr)
- EC2 t3.micro bastion: $0.0104/hr
- **Total: ~$1.14/hr**

### References

All claims verified against current AWS documentation as of 2026-09-28:
- MSK Serverless: https://docs.aws.amazon.com/msk/latest/developerguide/serverless.html
- MSK Connect: https://docs.aws.amazon.com/msk/latest/developerguide/msk-connect.html
- MSK Serverless limits: https://docs.aws.amazon.com/msk/latest/developerguide/limits.html
- Debezium: https://debezium.io/releases/
- Pricing: https://aws.amazon.com/msk/pricing/
