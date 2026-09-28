# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2024-12-20

### Added

- Initial release of AWS CDC Lakehouse Starter
- Complete Terraform infrastructure for CDC pipeline
  - RDS Postgres 16 with logical replication
  - Amazon MSK provisioned cluster (kafka.t3.small) with IAM auth
  - MSK Connect with Debezium Postgres connector (v2.5.4) and Iceberg sink (v1.4.3)
  - Private VPC with VPC endpoints (no NAT gateway)
  - S3 bucket for Iceberg tables and connector plugins
  - Glue Data Catalog for Iceberg metadata
  - Athena workgroup and named queries
  - Bastion instance for SSM-based RDS access
- Operational scripts
  - `make doctor`: Pre-flight checks (credentials, tools, quotas, cost estimation)
  - `make apply/destroy`: Infrastructure lifecycle
  - `make seed`: Schema creation and seed data
  - `make smoke`: End-to-end smoke test with measured latency
  - `make load`: Python load generator
  - `make verify-clean`: Post-destroy verification
- Documentation
  - Comprehensive README with architecture decisions and honest limitations
  - Architecture diagram (generated from Python diagrams library)
  - Runbooks for schema changes, connector restart, replay, and replication slot management
- CI/CD
  - GitHub Actions workflow for Terraform validation, linting, and testing
  - No AWS credentials required for CI
- IAM roles scoped to specific resources (MSK cluster, topics, S3 prefixes, Glue database)
- CloudWatch Logs for MSK and MSK Connect with 7-day retention
- Debezium using pgoutput plugin (built-in, no RDS extensions required)
- Iceberg format v2 with upsert mode for handling updates and deletes
- Sample schema: customers, orders, order_items with primary keys
- Athena named queries including Iceberg time-travel examples

### Design Decisions

- **Provisioned MSK instead of MSK Serverless**: MSK Connect does not support MSK Serverless as of Dec 2024
- **VPC Interface Endpoints instead of NAT Gateway**: Simplified architecture, acceptable cost for short tests
- **pgoutput plugin**: Built into Postgres 10+, no custom extensions needed in RDS
- **SSM Session Manager for bastion access**: No SSH keys, no public ports, session logging available
- **RDS-managed passwords in Secrets Manager**: No plaintext credentials in Terraform state
- **MSK Connect Secrets Manager config provider**: Connectors fetch RDS password at runtime

### Known Limitations

- Single AWS account, no multi-environment setup
- Single Postgres source database
- No schema registry (plain JSON events)
- Simplified IAM (some `Resource: "*"` for VPC operations)
- No customer-managed KMS keys
- No monitoring dashboards or alarms
- Basic CloudWatch logging, no tracing
- No automated backup/restore or DR
- Bash 3.2 compatibility (macOS default), no modern bashisms

### Verified Compatibility

- Terraform AWS provider ~> 5.0
- Debezium Postgres Connector 2.5.4.Final with Kafka Connect 3.5.x
- Apache Iceberg Kafka Connect 1.4.3 with Kafka Connect 3.5.x
- RDS Postgres 16.3
- MSK Kafka 3.5.1
- MSK Connect runtime 2.7.1 (Kafka Connect 3.5.1)
- Python 3.9+
- AWS CLI v1 and v2
