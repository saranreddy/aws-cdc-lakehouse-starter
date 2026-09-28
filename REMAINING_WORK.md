# REMAINING WORK BREAKDOWN - Detailed Implementation Guide

**Last Updated**: 2026-09-28 15:03 UTC  
**Current Completion**: ~40%  
**Remaining Estimated Time**: 4-6 hours

## What's Complete ✅

### 1. Architecture Decisions Verified
- MSK Serverless + MSK Connect compatibility confirmed
- Connector versions chosen and verified available
- Topic requirements documented (5 compacted, 3 non-compacted)
- IAM-only authentication confirmed

### 2. Infrastructure (Partial)
- MSK module rewritten for `aws_msk_serverless_cluster`
- Security groups updated for IAM auth (port 9098)
- Topic creation script complete (scripts/create-topics.sh)
- Plugin download logic updated (Debezium 2.7.3.Final, Tabular 0.6.19)

### 3. Scripts
- create-topics.sh: Complete and working
- seed.sh: Updated to call topic creation
- Other scripts: Need updates for Serverless

## What Remains - Critical Path

### 1. Complete MSK Connect Module (2-3 hours)

**File**: `terraform/modules/msk-connect/main.tf`

**Missing**: MSK Connect Custom Plugin and Connector resources

**Add these resources**:

```hcl
# Debezium custom plugin
resource "aws_mskconnect_custom_plugin" "debezium" {
  name         = "${var.name_prefix}-debezium-postgres-${var.random_suffix}"
  content_type = "ZIP"

  location {
    s3 {
      bucket_arn = var.s3_bucket_arn
      file_key   = "plugins/debezium-postgres-connector-2.7.3.Final.zip"
    }
  }

  depends_on = [null_resource.fetch_debezium_plugin]
}

# Iceberg custom plugin
resource "aws_mskconnect_custom_plugin" "iceberg" {
  name         = "${var.name_prefix}-iceberg-sink-${var.random_suffix}"
  content_type = "ZIP"

  location {
    s3 {
      bucket_arn = var.s3_bucket_arn
      file_key   = "plugins/iceberg-kafka-connect-0.6.19.zip"
    }
  }

  depends_on = [null_resource.fetch_iceberg_plugin]
}

# Debezium source connector
resource "aws_mskconnect_connector" "debezium_postgres" {
  name = "${var.name_prefix}-debezium-postgres-${var.random_suffix}"

  kafkaconnect_version = "3.7.1"

  capacity {
    autoscaling {
      mcu_count        = 1
      min_worker_count = 1
      max_worker_count = 2
      
      scale_in_policy {
        cpu_utilization_percentage = 20
      }
      
      scale_out_policy {
        cpu_utilization_percentage = 80
      }
    }
  }

  connector_configuration = {
    "connector.class"                      = "io.debezium.connector.postgresql.PostgresConnector"
    "tasks.max"                            = "1"
    
    # Database connection
    "database.hostname"                    = var.rds_endpoint
    "database.port"                        = var.rds_port
    "database.user"                        = var.rds_master_username
    "database.password"                    = "\${secretManager:${var.rds_secret_arn}:password::}"
    "database.dbname"                      = var.rds_database_name
    "database.server.name"                 = var.name_prefix
    
    # Replication
    "plugin.name"                          = "pgoutput"
    "slot.name"                            = "cdc_lakehouse_slot"
    "publication.name"                     = "cdc_publication"
    
    # Topic names (Serverless pre-created)
    "topic.prefix"                         = var.name_prefix
    "schema.history.internal.kafka.topic"  = "${var.name_prefix}.schema-history"
    
    # Kafka cluster (IAM auth for Serverless)
    "key.converter"                        = "org.apache.kafka.connect.storage.StringConverter"
    "value.converter"                      = "io.confluent.connect.avro.AvroConverter"
    "value.converter.schema.registry.url"  = "http://not-used"
    "value.converter.schemas.enable"       = "false"
    
    # Snapshot mode
    "snapshot.mode"                        = "initial"
    "table.include.list"                   = "public.customers,public.orders,public.order_items"
  }

  kafka_cluster {
    apache_kafka_cluster {
      bootstrap_servers = var.msk_bootstrap_brokers

      vpc {
        security_groups = var.security_group_ids
        subnets         = var.subnet_ids
      }
    }
  }

  kafka_cluster_client_authentication {
    authentication_type = "IAM"
  }

  kafka_cluster_encryption_in_transit {
    encryption_type = "TLS"
  }

  plugin {
    custom_plugin {
      arn      = aws_mskconnect_custom_plugin.debezium.arn
      revision = aws_mskconnect_custom_plugin.debezium.latest_revision
    }
  }

  service_execution_role_arn = var.debezium_role_arn

  depends_on = [aws_mskconnect_custom_plugin.debezium]
}

# Iceberg sink connector
resource "aws_mskconnect_connector" "iceberg_sink" {
  name = "${var.name_prefix}-iceberg-sink-${var.random_suffix}"

  kafkaconnect_version = "3.7.1"

  capacity {
    autoscaling {
      mcu_count        = 1
      min_worker_count = 1
      max_worker_count = 2
      
      scale_in_policy {
        cpu_utilization_percentage = 20
      }
      
      scale_out_policy {
        cpu_utilization_percentage = 80
      }
    }
  }

  connector_configuration = {
    "connector.class" = "io.tabular.iceberg.connect.IcebergSinkConnector"
    "tasks.max"       = "1"
    
    # Topics
    "topics"                     = "${var.name_prefix}.public.customers,${var.name_prefix}.public.orders,${var.name_prefix}.public.order_items"
    "iceberg.control.topic"      = "control-iceberg"
    "iceberg.control.commit.interval.ms" = "300000"
    
    # Iceberg catalog (AWS Glue)
    "iceberg.catalog"                  = "glue"
    "iceberg.catalog.glue.catalog-id"  = var.glue_catalog_id
    "iceberg.catalog.glue.warehouse"   = "s3://${var.s3_bucket_name}/iceberg/"
    "iceberg.catalog.glue.id"          = var.glue_catalog_id
    
    # Table configuration
    "iceberg.tables"                         = "${var.glue_database_name}.customers,${var.glue_database_name}.orders,${var.glue_database_name}.order_items"
    "iceberg.tables.upsert-mode-enabled"     = "true"
    "iceberg.tables.evolve-schema-enabled"   = "true"
    "iceberg.tables.auto-create-enabled"     = "true"
    "iceberg.tables.default-commit-branch"   = "main"
    
    # Value format
    "value.converter"                  = "io.confluent.connect.avro.AvroConverter"
    "value.converter.schemas.enable"   = "false"
    "key.converter"                    = "org.apache.kafka.connect.storage.StringConverter"
  }

  kafka_cluster {
    apache_kafka_cluster {
      bootstrap_servers = var.msk_bootstrap_brokers

      vpc {
        security_groups = var.security_group_ids
        subnets         = var.subnet_ids
      }
    }
  }

  kafka_cluster_client_authentication {
    authentication_type = "IAM"
  }

  kafka_cluster_encryption_in_transit {
    encryption_type = "TLS"
  }

  plugin {
    custom_plugin {
      arn      = aws_mskconnect_custom_plugin.iceberg.arn
      revision = aws_mskconnect_custom_plugin.iceberg.latest_revision
    }
  }

  service_execution_role_arn = var.iceberg_role_arn

  depends_on = [
    aws_mskconnect_custom_plugin.iceberg,
    aws_mskconnect_connector.debezium_postgres
  ]
}
```

**Key Points**:
- `kafkaconnect_version = "3.7.1"` (verified available)
- IAM authentication for MSK Serverless
- Pre-created topic names (no auto-creation)
- Tabular Iceberg 0.6.19 configuration syntax
- Glue catalog integration

### 2. Update IAM Policies for Serverless (30 minutes)

**File**: `terraform/modules/iam/main.tf`

**Issue**: Current policies use provisioned MSK ARN patterns

**MSK Serverless ARN Formats**:
```
Cluster: arn:aws:kafka:region:account:cluster/cluster-name/uuid
Topic:   arn:aws:kafka:region:account:topic/cluster-name-uuid/topic-name
Group:   arn:aws:kafka:region:account:group/cluster-name-uuid/group-name
```

**Update Required**:
- Debezium connector IAM role: Add Serverless cluster/topic/group ARN patterns
- Iceberg connector IAM role: Add Serverless cluster/topic/group ARN patterns + Glue permissions

**Example Policy Update**:
```hcl
# In debezium connector policy
{
  Effect = "Allow"
  Action = [
    "kafka-cluster:Connect",
    "kafka-cluster:AlterCluster",
    "kafka-cluster:DescribeCluster"
  ]
  Resource = var.msk_cluster_arn  # Serverless cluster ARN
}
{
  Effect = "Allow"
  Action = [
    "kafka-cluster:*Topic*",
    "kafka-cluster:WriteData",
    "kafka-cluster:ReadData"
  ]
  Resource = "arn:aws:kafka:${var.region}:${data.aws_caller_identity.current.account_id}:topic/${split("/", var.msk_cluster_arn)[1]}/*"
}
{
  Effect = "Allow"
  Action = [
    "kafka-cluster:AlterGroup",
    "kafka-cluster:DescribeGroup"
  ]
  Resource = "arn:aws:kafka:${var.region}:${data.aws_caller_identity.current.account_id}:group/${split("/", var.msk_cluster_arn)[1]}/*"
}
```

### 3. Generate Architecture Diagram (30 minutes)

**File**: `docs/architecture.py`

**Steps**:
1. Install dependencies: `apt-get install graphviz && pip3 install diagrams`
2. Fix icon imports (current ones don't exist)
3. Update for Serverless architecture
4. Run: `python3 docs/architecture.py`
5. Commit generated `docs/architecture.png`

**Icon Fix Needed**:
```python
from diagrams import Diagram, Cluster, Edge
from diagrams.aws.compute import EC2
from diagrams.aws.database import RDS
from diagrams.aws.analytics import Glue, Athena
from diagrams.aws.storage import S3
from diagrams.aws.network import Endpoint, InternetGateway, NATGateway
from diagrams.aws.integration import SimpleQueueServiceSqs as SQS  # Placeholder for MSK
from diagrams.aws.management import Cloudwatch

# Use SQS icon as placeholder for MSK Serverless (no official icon)
# Use EC2 icon for MSK Connect workers
```

**Architecture Elements**:
- RDS Postgres (logical replication)
- MSK Serverless cluster (IAM auth)
- MSK Connect (Debezium + Iceberg)
- S3 (Iceberg tables)
- Glue Data Catalog
- Athena
- VPC + Private subnets + Interface endpoints
- Bastion (public subnet)

### 4. Recalculate Costs (1 hour)

**Fetch 2026-09-28 Pricing From**:
- https://aws.amazon.com/msk/pricing/
- https://aws.amazon.com/rds/postgresql/pricing/
- https://aws.amazon.com/ec2/pricing/on-demand/
- https://aws.amazon.com/vpc/pricing/
- https://aws.amazon.com/s3/pricing/
- https://aws.amazon.com/athena/pricing/

**Components to Price** (us-east-1):
1. **MSK Serverless**:
   - Cluster-hour: $0.75/hr
   - Partition-hours: 15 partitions × $0.0015/hr = $0.0225/hr
   - Subtotal: ~$0.77/hr

2. **MSK Connect**:
   - 2 connectors × 1 MCU × $0.11/MCU-hr = $0.22/hr

3. **RDS db.t4g.micro**:
   - On-Demand: ~$0.016/hr (verify current price)

4. **VPC Interface Endpoints** (6 endpoints × 2 AZs):
   - $0.01/AZ-hr × 12 = $0.12/hr

5. **EC2 t3.micro bastion**:
   - $0.0104/hr (verify current price)

6. **Total Hourly**: ~$1.13/hr

**Update Locations**:
- `README.md` cost section
- `scripts/doctor.sh` estimates
- `PR description`

### 5. Documentation Rewrite (2 hours)

**Files to Update**:

**README.md**:
- [ ] Remove all "provisioned MSK" language
- [ ] Update architecture section for Serverless
- [ ] Update cost section with 2026-09-28 pricing
- [ ] Update "How It Works" for topic pre-creation
- [ ] Add Serverless limitations section
- [ ] Update all dates to 2026-09-28

**CHANGELOG.md**:
- [ ] Correct v0.1.0 entry
- [ ] Update connector versions (2.7.3.Final, 0.6.19)
- [ ] Note MSK Serverless decision
- [ ] Correct all facts

**Runbooks** (`docs/runbooks/*.md`):
- [ ] schema-changes.md: Serverless-specific notes
- [ ] connector-restart.md: Same process (no changes)
- [ ] replay.md: Topic retention config for Serverless
- [ ] replication-slot.md: Same (no changes)

**Scripts**:
- [ ] doctor.sh: Update cost estimates, remove broker checks
- [ ] verify-clean.sh: Update for Serverless cluster deletion
- [ ] smoke.sh: Verify works with Serverless (likely no changes)

**Grep for Stale Text**:
```bash
grep -r "kafka.t3" . --exclude-dir=.git
grep -r "broker_count" . --exclude-dir=.git
grep -r "msk_instance_type" . --exclude-dir=.git
grep -r "9094" . --exclude-dir=.git --exclude-dir=node_modules
grep -r "Dec 2024" . --exclude-dir=.git
grep -r "2024-12" . --exclude-dir=.git
grep -r "provisioned" . --exclude-dir=.git | grep -i msk
```

### 6. CI Fixes (1 hour)

**Ensure These Pass**:
- [ ] Terraform format: `terraform fmt -check -recursive`
- [ ] Terraform validate: `cd terraform && terraform init -backend=false && terraform validate`
- [ ] Shellcheck: `shellcheck scripts/*.sh`
- [ ] Python tests: `pytest tests/`
- [ ] Bash 3.2 compat: Check scripts (no associative arrays, mapfile, ${var,,})
- [ ] Architecture diagram: `python3 docs/architecture.py`

**Known Issues to Fix**:
- Architecture diagram icon imports
- Terraform validation (modules incomplete currently)

## Priority Order

1. **MSK Connect module completion** (blocks everything else)
2. **IAM policy updates** (blocks testing)
3. **Architecture diagram generation** (for documentation)
4. **Cost recalculation** (for README/PR)
5. **Documentation rewrite** (last step)
6. **CI green** (validation)

## Testing Checklist (After Completion)

- [ ] `terraform fmt` passes
- [ ] `terraform validate` passes  
- [ ] All shellcheck warnings resolved
- [ ] Python unit tests pass
- [ ] Architecture PNG renders correctly
- [ ] README has no broker references
- [ ] All dates are 2026-09-28
- [ ] All prices current as of 2026-09-28
- [ ] No "Dec 2024" anywhere
- [ ] CI all green

## Honest Time Estimate

- MSK Connect: 2-3 hours
- IAM: 30 min
- Diagram: 30 min
- Costs: 1 hour
- Docs: 2 hours
- Testing/fixes: 1 hour

**Total: 6-7 hours of focused work**

## Notes for Continuation

This PR represents a major architectural pivot. The work done is high-quality and research-based, but implementation is only ~40% complete. The remaining work is well-defined and follows a clear critical path.

**User decision**: Continue until complete.
