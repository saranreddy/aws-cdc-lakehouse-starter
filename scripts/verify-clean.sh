#!/bin/bash
set -e

echo "=== Verify Clean Teardown ==="
echo ""

REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")
NAME_PREFIX="${1:-cdc-lakehouse}"

echo "Checking for remaining billable resources..."
echo "  Region: $REGION"
echo "  Name prefix: $NAME_PREFIX"
echo ""

ISSUES=0

# Check RDS instances
echo -n "Checking RDS instances... "
RDS_INSTANCES=$(aws rds describe-db-instances \
    --region "$REGION" \
    --query "DBInstances[?starts_with(DBInstanceIdentifier, '$NAME_PREFIX')].DBInstanceIdentifier" \
    --output text 2>/dev/null || echo "")

if [ -n "$RDS_INSTANCES" ]; then
    echo "FOUND"
    echo "  Instances: $RDS_INSTANCES"
    ISSUES=$((ISSUES + 1))
else
    echo "OK"
fi

# Check RDS snapshots
echo -n "Checking RDS snapshots... "
RDS_SNAPSHOTS=$(aws rds describe-db-snapshots \
    --region "$REGION" \
    --query "DBSnapshots[?starts_with(DBSnapshotIdentifier, '$NAME_PREFIX')].DBSnapshotIdentifier" \
    --output text 2>/dev/null || echo "")

if [ -n "$RDS_SNAPSHOTS" ]; then
    echo "FOUND"
    echo "  Snapshots: $RDS_SNAPSHOTS"
    ISSUES=$((ISSUES + 1))
else
    echo "OK"
fi

# Check MSK clusters
echo -n "Checking MSK clusters... "
MSK_CLUSTERS=$(aws kafka list-clusters \
    --region "$REGION" \
    --query "ClusterInfoList[?starts_with(ClusterName, '$NAME_PREFIX')].ClusterName" \
    --output text 2>/dev/null || echo "")

if [ -n "$MSK_CLUSTERS" ]; then
    echo "FOUND"
    echo "  Clusters: $MSK_CLUSTERS"
    ISSUES=$((ISSUES + 1))
else
    echo "OK"
fi

# Check MSK Connect connectors
echo -n "Checking MSK Connect connectors... "
MSK_CONNECTORS=$(aws kafkaconnect list-connectors \
    --region "$REGION" \
    --query "connectors[?starts_with(connectorName, '$NAME_PREFIX')].connectorName" \
    --output text 2>/dev/null || echo "")

if [ -n "$MSK_CONNECTORS" ]; then
    echo "FOUND"
    echo "  Connectors: $MSK_CONNECTORS"
    ISSUES=$((ISSUES + 1))
else
    echo "OK"
fi

# Check MSK Connect custom plugins
echo -n "Checking MSK Connect custom plugins... "
MSK_PLUGINS=$(aws kafkaconnect list-custom-plugins \
    --region "$REGION" \
    --query "customPlugins[?starts_with(name, '$NAME_PREFIX')].name" \
    --output text 2>/dev/null || echo "")

if [ -n "$MSK_PLUGINS" ]; then
    echo "FOUND"
    echo "  Plugins: $MSK_PLUGINS"
    echo "  Note: Custom plugins may take several minutes to delete after connectors are removed"
    ISSUES=$((ISSUES + 1))
else
    echo "OK"
fi

# Check VPC endpoints
echo -n "Checking VPC interface endpoints... "
VPC_ENDPOINTS=$(aws ec2 describe-vpc-endpoints \
    --region "$REGION" \
    --filters "Name=tag:NamePrefix,Values=$NAME_PREFIX" "Name=vpc-endpoint-type,Values=Interface" \
    --query "VpcEndpoints[].VpcEndpointId" \
    --output text 2>/dev/null || echo "")

if [ -n "$VPC_ENDPOINTS" ]; then
    echo "FOUND"
    echo "  Endpoints: $VPC_ENDPOINTS"
    ISSUES=$((ISSUES + 1))
else
    echo "OK"
fi

# Check S3 buckets
echo -n "Checking S3 buckets... "
S3_BUCKETS=$(aws s3api list-buckets \
    --region "$REGION" \
    --query "Buckets[?starts_with(Name, '$NAME_PREFIX')].Name" \
    --output text 2>/dev/null || echo "")

if [ -n "$S3_BUCKETS" ]; then
    echo "FOUND"
    echo "  Buckets: $S3_BUCKETS"
    ISSUES=$((ISSUES + 1))
else
    echo "OK"
fi

# Check Glue databases
echo -n "Checking Glue databases... "
GLUE_DBS=$(aws glue get-databases \
    --region "$REGION" \
    --query "DatabaseList[?starts_with(Name, '${NAME_PREFIX}_')].Name" \
    --output text 2>/dev/null || echo "")

if [ -n "$GLUE_DBS" ]; then
    echo "FOUND"
    echo "  Databases: $GLUE_DBS"
    ISSUES=$((ISSUES + 1))
else
    echo "OK"
fi

# Check CloudWatch Log Groups
echo -n "Checking CloudWatch Log Groups... "
LOG_GROUPS=$(aws logs describe-log-groups \
    --region "$REGION" \
    --log-group-name-prefix "/aws/msk/${NAME_PREFIX}" \
    --query "logGroups[].logGroupName" \
    --output text 2>/dev/null || echo "")

LOG_GROUPS2=$(aws logs describe-log-groups \
    --region "$REGION" \
    --log-group-name-prefix "/aws/msk-connect/${NAME_PREFIX}" \
    --query "logGroups[].logGroupName" \
    --output text 2>/dev/null || echo "")

if [ -n "$LOG_GROUPS" ] || [ -n "$LOG_GROUPS2" ]; then
    echo "FOUND"
    if [ -n "$LOG_GROUPS" ]; then
        echo "  MSK logs: $LOG_GROUPS"
    fi
    if [ -n "$LOG_GROUPS2" ]; then
        echo "  Connector logs: $LOG_GROUPS2"
    fi
    echo "  Note: Log groups are low cost (\$0.50/GB stored) and may be kept for audit trail"
else
    echo "OK"
fi

# Check Secrets Manager secrets
echo -n "Checking Secrets Manager secrets... "
SECRETS=$(aws secretsmanager list-secrets \
    --region "$REGION" \
    --query "SecretList[?contains(Name, '$NAME_PREFIX')].Name" \
    --output text 2>/dev/null || echo "")

if [ -n "$SECRETS" ]; then
    echo "FOUND"
    echo "  Secrets: $SECRETS"
    ISSUES=$((ISSUES + 1))
else
    echo "OK"
fi

# Check EC2 instances
echo -n "Checking EC2 instances (bastion)... "
EC2_INSTANCES=$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters "Name=tag:NamePrefix,Values=$NAME_PREFIX" "Name=instance-state-name,Values=running,stopped,stopping,pending" \
    --query "Reservations[].Instances[].InstanceId" \
    --output text 2>/dev/null || echo "")

if [ -n "$EC2_INSTANCES" ]; then
    echo "FOUND"
    echo "  Instances: $EC2_INSTANCES"
    ISSUES=$((ISSUES + 1))
else
    echo "OK"
fi

echo ""
echo "=== Debezium Replication Slot Information ==="
echo ""
echo "Important: Debezium creates a PostgreSQL replication slot named 'debezium_slot'"
echo "in RDS. This slot holds WAL segments to track the CDC position."
echo ""
echo "Behavior:"
echo "  - If RDS is deleted, the slot is automatically removed"
echo "  - If the connector is deleted but RDS remains, the slot persists"
echo "  - An unused slot can cause WAL growth and storage costs"
echo ""
echo "To manually check and delete the slot if RDS still exists:"
echo "  1. Connect to RDS: psql -h <endpoint> -U postgres -d cdc_demo"
echo "  2. List slots: SELECT * FROM pg_replication_slots;"
echo "  3. Drop slot: SELECT pg_drop_replication_slot('debezium_slot');"
echo ""

# Summary
echo "=== Summary ==="
if [ $ISSUES -eq 0 ]; then
    echo "No billable resources found. Clean!"
    exit 0
else
    echo "Found $ISSUES types of resources still present."
    echo "These may incur costs. Review and remove manually if needed."
    exit 1
fi
