# REBUILD STATUS - 2026-09-28

## Verified Facts (with citations)

### MSK Serverless + MSK Connect Compatibility
✅ **CONFIRMED**: MSK Connect works with MSK Serverless
- Source: https://docs.aws.amazon.com/msk/latest/developerguide/msk-connect.html
- Quote: "MSK Connect supports connectors for any Apache Kafka cluster with connectivity to an Amazon VPC, whether it is an MSK cluster or an independently hosted Apache Kafka cluster."
- AWS re:Post confirmation: "MSK Connect now works with MSK Serverless" (answered 3 years ago)
- Verified: 2026-09-28

### MSK Serverless Requirements
- **IAM Authentication Only**: MSK Serverless requires IAM access control for all clusters. Apache Kafka ACLs not supported.
- **No Auto-Topic Creation**: Topics must be explicitly created using Kafka admin tools
- **Partition Limits**: 2,400 for non-compacted topics, 120 for compacted topics (per cluster)
- **Compacted Topic Limit Critical**: Kafka Connect internal topics (offsets, configs, status) are compacted
- Source: https://docs.aws.amazon.com/msk/latest/developerguide/limits.html, verified 2026-09-28

### MSK Connect Runtime
- **Kafka Connect Versions**: 2.7.1 or 3.7.x
- Source: https://docs.aws.amazon.com/msk/latest/developerguide/msk-connect.html, verified 2026-09-28

### Connector Versions (Verified Compatibility)
1. **Debezium Postgres 2.7.3.Final**
   - Maven Central: https://repo1.maven.org/maven2/io/debezium/debezium-connector-postgres/2.7.3.Final/
   - Artifact: debezium-connector-postgres-2.7.3.Final-plugin.tar.gz  
   - Verified exists: curl -I returned HTTP/2 200
   - Java requirement: Java 11+
   - Kafka Connect: 2.x, 3.x compatible
   - Rationale: Most stable version compatible with MSK Connect 3.7.x runtime (Java 11)

2. **Iceberg Kafka Connect**: TBD - Need to choose between:
   - Apache Iceberg built-in (1.7+, requires build from source)
   - Tabular 0.6.19 (archived project, no download artifacts in GitHub releases)

## Changes Made

### Completed
- ✅ Installed Terraform 1.5.7
- ✅ Created MSK Serverless cluster resource (aws_msk_serverless_cluster)
- ✅ Removed broker-type/broker-count variables
- ✅ Updated security group for IAM-only access (port 9098)
- ✅ Fixed S3 lifecycle configuration warning

### In Progress
- 🔄 MSK Connect module rewrite for correct connector versions
- 🔄 Topic pre-creation module (Kafka Connect internals + application topics)
- 🔄 IAM policy updates for Serverless cluster ARNs
- 🔄 Cost recalculation from 2026-09-28 pricing

### Not Started
- ❌ Architecture diagram generation (docs/architecture.png)
- ❌ README complete rewrite
- ❌ CHANGELOG update
- ❌ Runbook updates (Serverless-specific)
- ❌ doctor.sh cost estimates
- ❌ verify-clean.sh (Serverless clusters)
- ❌ Remove all provisioned-MSK references

## Remaining Work

1. **Choose and Implement Iceberg Connector**
2. **MSK Connect Module Complete Rewrite**
3. **Topic Creation Module** (pre-create all topics Serverless requires)
4. **IAM Policies** (update for Serverless ARN patterns)
5. **Architecture Diagram** (generate PNG with correct icons)
6. **Documentation** (README, CHANGELOG, runbooks)
7. **Scripts** (doctor, verify-clean)
8. **CI** (ensure all checks pass)
9. **Cost Recalculation** (MSK Serverless pricing model)

## Estimated Time Remaining
- Core infrastructure: 2-3 hours
- Documentation: 1-2 hours
- Testing/validation: 1 hour
