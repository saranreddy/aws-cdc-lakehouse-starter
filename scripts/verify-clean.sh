#!/bin/bash
set -e

echo "=== Verify Clean Teardown ==="
echo ""

# Get region with proper validation and fallback
REGION=""
if [ -d "terraform" ] && [ -f "terraform/terraform.tfstate" ]; then
    REGION=$(cd terraform && terraform output -raw region 2>/dev/null || true)
fi

# Validate region format
if [ -n "$REGION" ] && ! echo "$REGION" | grep -Eq '^[a-z]{2}(-[a-z]+)+-[0-9]$'; then
    echo "Warning: Invalid region format from terraform: $REGION"
    REGION=""
fi

# Fallback chain
if [ -z "$REGION" ]; then
    REGION="${AWS_REGION:-}"
fi
if [ -z "$REGION" ]; then
    REGION="${AWS_DEFAULT_REGION:-}"
fi
if [ -z "$REGION" ]; then
    # Read from terraform.tfvars as last resort
    if [ -f "terraform/terraform.tfvars" ]; then
        REGION=$(grep '^region' terraform/terraform.tfvars | cut -d'"' -f2 2>/dev/null || echo "us-east-1")
    else
        REGION="us-east-1"
    fi
fi

# Final validation
if ! echo "$REGION" | grep -Eq '^[a-z]{2}(-[a-z]+)+-[0-9]$'; then
    echo "Error: Could not determine valid AWS region"
    exit 1
fi

NAME_PREFIX="${1:-cdc-lakehouse}"

echo "Checking for remaining billable resources..."
echo "  Region: $REGION"
echo "  Name prefix: $NAME_PREFIX"
echo ""

ISSUES=0

# Helper function: run AWS CLI and treat errors as failures
aws_check() {
    local output
    if ! output=$(eval "$1" 2>&1); then
        echo "ERROR: AWS CLI failed"
        echo "  Command: $1"
        echo "  Output: $output"
        return 1
    fi
    echo "$output"
}

# Check VPCs
echo -n "Checking VPCs... "
VPCS=$(aws_check "aws ec2 describe-vpcs --region '$REGION' --filters 'Name=tag:Name,Values=${NAME_PREFIX}-*' --query 'Vpcs[].VpcId' --output text") || exit 1
if [ -n "$VPCS" ] && [ "$VPCS" != "None" ]; then
    echo "FOUND: $VPCS"
    ISSUES=$((ISSUES + 1))
else
    echo "OK"
fi

# Check subnets
echo -n "Checking subnets... "
SUBNETS=$(aws_check "aws ec2 describe-subnets --region '$REGION' --filters 'Name=tag:Name,Values=${NAME_PREFIX}-*' --query 'Subnets[].SubnetId' --output text") || exit 1
if [ -n "$SUBNETS" ] && [ "$SUBNETS" != "None" ]; then
    echo "FOUND: $SUBNETS"
    ISSUES=$((ISSUES + 1))
else
    echo "OK"
fi

# Check security groups
echo -n "Checking security groups... "
SGS=$(aws_check "aws ec2 describe-security-groups --region '$REGION' --filters 'Name=tag:Name,Values=${NAME_PREFIX}-*' --query 'SecurityGroups[].GroupId' --output text") || exit 1
if [ -n "$SGS" ] && [ "$SGS" != "None" ]; then
    echo "FOUND: $SGS"
    ISSUES=$((ISSUES + 1))
else
    echo "OK"
fi

# Check network interfaces
echo -n "Checking network interfaces... "
ENIS=$(aws_check "aws ec2 describe-network-interfaces --region '$REGION' --filters 'Name=tag:Name,Values=${NAME_PREFIX}-*' --query 'NetworkInterfaces[].NetworkInterfaceId' --output text") || exit 1
if [ -n "$ENIS" ] && [ "$ENIS" != "None" ]; then
    echo "FOUND: $ENIS"
    ISSUES=$((ISSUES + 1))
else
    echo "OK"
fi

# Check Elastic IPs
echo -n "Checking Elastic IPs... "
EIPS=$(aws_check "aws ec2 describe-addresses --region '$REGION' --filters 'Name=tag:Name,Values=${NAME_PREFIX}-*' --query 'Addresses[].AllocationId' --output text") || exit 1
if [ -n "$EIPS" ] && [ "$EIPS" != "None" ]; then
    echo "FOUND: $EIPS"
    ISSUES=$((ISSUES + 1))
else
    echo "OK"
fi

# Check NAT gateways
echo -n "Checking NAT gateways... "
NATS=$(aws_check "aws ec2 describe-nat-gateways --region '$REGION' --filter 'Name=tag:Name,Values=${NAME_PREFIX}-*' --query 'NatGateways[?State!=\`deleted\`].NatGatewayId' --output text") || exit 1
if [ -n "$NATS" ] && [ "$NATS" != "None" ]; then
    echo "FOUND: $NATS"
    ISSUES=$((ISSUES + 1))
else
    echo "OK"
fi

# Check VPC endpoints
echo -n "Checking VPC endpoints... "
ENDPOINTS=$(aws_check "aws ec2 describe-vpc-endpoints --region '$REGION' --filters 'Name=tag:Name,Values=${NAME_PREFIX}-*' --query 'VpcEndpoints[].VpcEndpointId' --output text") || exit 1
if [ -n "$ENDPOINTS" ] && [ "$ENDPOINTS" != "None" ]; then
    echo "FOUND: $ENDPOINTS"
    ISSUES=$((ISSUES + 1))
else
    echo "OK"
fi

# Check RDS instances
echo -n "Checking RDS instances... "
RDS_INSTANCES=$(aws_check "aws rds describe-db-instances --region '$REGION' --query \"DBInstances[?starts_with(DBInstanceIdentifier, '$NAME_PREFIX')].DBInstanceIdentifier\" --output text") || exit 1
if [ -n "$RDS_INSTANCES" ] && [ "$RDS_INSTANCES" != "None" ]; then
    echo "FOUND: $RDS_INSTANCES"
    ISSUES=$((ISSUES + 1))
else
    echo "OK"
fi

# Check RDS parameter groups
echo -n "Checking RDS parameter groups... "
RDS_PGS=$(aws_check "aws rds describe-db-parameter-groups --region '$REGION' --query \"DBParameterGroups[?starts_with(DBParameterGroupName, '$NAME_PREFIX')].DBParameterGroupName\" --output text") || exit 1
if [ -n "$RDS_PGS" ] && [ "$RDS_PGS" != "None" ]; then
    echo "FOUND: $RDS_PGS"
    ISSUES=$((ISSUES + 1))
else
    echo "OK"
fi

# Check RDS subnet groups
echo -n "Checking RDS subnet groups... "
RDS_SUBNETS=$(aws_check "aws rds describe-db-subnet-groups --region '$REGION' --query \"DBSubnetGroups[?starts_with(DBSubnetGroupName, '$NAME_PREFIX')].DBSubnetGroupName\" --output text") || exit 1
if [ -n "$RDS_SUBNETS" ] && [ "$RDS_SUBNETS" != "None" ]; then
    echo "FOUND: $RDS_SUBNETS"
    ISSUES=$((ISSUES + 1))
else
    echo "OK"
fi

# Check MSK clusters
echo -n "Checking MSK clusters... "
MSK_CLUSTERS=$(aws_check "aws kafka list-clusters-v2 --region '$REGION' --query \"ClusterInfoList[?starts_with(ClusterName, '$NAME_PREFIX')].ClusterName\" --output text") || exit 1
if [ -n "$MSK_CLUSTERS" ] && [ "$MSK_CLUSTERS" != "None" ]; then
    echo "FOUND: $MSK_CLUSTERS"
    ISSUES=$((ISSUES + 1))
else
    echo "OK"
fi

# Check MSK Connect connectors
echo -n "Checking MSK Connect connectors... "
MSK_CONNECTORS=$(aws_check "aws kafkaconnect list-connectors --region '$REGION' --query \"connectors[?starts_with(connectorName, '$NAME_PREFIX')].connectorName\" --output text") || exit 1
if [ -n "$MSK_CONNECTORS" ] && [ "$MSK_CONNECTORS" != "None" ]; then
    echo "FOUND: $MSK_CONNECTORS"
    ISSUES=$((ISSUES + 1))
else
    echo "OK"
fi

# Check MSK Connect worker configurations
echo -n "Checking MSK Connect worker configs... "
WORKER_CONFIGS=$(aws_check "aws kafkaconnect list-worker-configurations --region '$REGION' --query \"workerConfigurations[?starts_with(name, '$NAME_PREFIX')].name\" --output text") || exit 1
if [ -n "$WORKER_CONFIGS" ] && [ "$WORKER_CONFIGS" != "None" ]; then
    echo "FOUND: $WORKER_CONFIGS"
    ISSUES=$((ISSUES + 1))
else
    echo "OK"
fi

# Check MSK Connect custom plugins
echo -n "Checking MSK Connect custom plugins... "
MSK_PLUGINS=$(aws_check "aws kafkaconnect list-custom-plugins --region '$REGION' --query \"customPlugins[?starts_with(name, '$NAME_PREFIX')].name\" --output text") || exit 1
if [ -n "$MSK_PLUGINS" ] && [ "$MSK_PLUGINS" != "None" ]; then
    echo "FOUND: $MSK_PLUGINS"
    ISSUES=$((ISSUES + 1))
else
    echo "OK"
fi

# Check S3 buckets
echo -n "Checking S3 buckets... "
S3_BUCKETS=$(aws_check "aws s3api list-buckets --query \"Buckets[?starts_with(Name, '$NAME_PREFIX')].Name\" --output text") || exit 1
if [ -n "$S3_BUCKETS" ] && [ "$S3_BUCKETS" != "None" ]; then
    echo "FOUND: $S3_BUCKETS"
    ISSUES=$((ISSUES + 1))
else
    echo "OK"
fi

# Check Glue databases
echo -n "Checking Glue databases... "
GLUE_DBS=$(aws_check "aws glue get-databases --region '$REGION' --query \"DatabaseList[?starts_with(Name, '${NAME_PREFIX//-/_}_')].Name\" --output text") || exit 1
if [ -n "$GLUE_DBS" ] && [ "$GLUE_DBS" != "None" ]; then
    echo "FOUND: $GLUE_DBS"
    ISSUES=$((ISSUES + 1))
else
    echo "OK"
fi

# Check IAM roles
echo -n "Checking IAM roles... "
IAM_ROLES=$(aws_check "aws iam list-roles --query \"Roles[?starts_with(RoleName, '$NAME_PREFIX')].RoleName\" --output text") || exit 1
if [ -n "$IAM_ROLES" ] && [ "$IAM_ROLES" != "None" ]; then
    echo "FOUND: $IAM_ROLES"
    ISSUES=$((ISSUES + 1))
else
    echo "OK"
fi

# Check IAM instance profiles
echo -n "Checking IAM instance profiles... "
IAM_PROFILES=$(aws_check "aws iam list-instance-profiles --query \"InstanceProfiles[?starts_with(InstanceProfileName, '$NAME_PREFIX')].InstanceProfileName\" --output text") || exit 1
if [ -n "$IAM_PROFILES" ] && [ "$IAM_PROFILES" != "None" ]; then
    echo "FOUND: $IAM_PROFILES"
    ISSUES=$((ISSUES + 1))
else
    echo "OK"
fi

# Check EC2 instances
echo -n "Checking EC2 instances... "
EC2_INSTANCES=$(aws_check "aws ec2 describe-instances --region '$REGION' --filters 'Name=tag:Name,Values=${NAME_PREFIX}-*' 'Name=instance-state-name,Values=running,stopped,stopping,pending' --query 'Reservations[].Instances[].InstanceId' --output text") || exit 1
if [ -n "$EC2_INSTANCES" ] && [ "$EC2_INSTANCES" != "None" ]; then
    echo "FOUND: $EC2_INSTANCES"
    ISSUES=$((ISSUES + 1))
else
    echo "OK"
fi

# Check Athena workgroups
echo -n "Checking Athena workgroups... "
ATHENA_WGS=$(aws_check "aws athena list-work-groups --region '$REGION' --query \"WorkGroups[?starts_with(Name, '$NAME_PREFIX')].Name\" --output text") || exit 1
if [ -n "$ATHENA_WGS" ] && [ "$ATHENA_WGS" != "None" ]; then
    echo "FOUND: $ATHENA_WGS"
    ISSUES=$((ISSUES + 1))
else
    echo "OK"
fi

# Check CloudWatch log groups
echo -n "Checking CloudWatch log groups... "
LOG_GROUPS=$(aws_check "aws logs describe-log-groups --region '$REGION' --log-group-name-prefix '/aws/' --query \"logGroups[?contains(logGroupName, '$NAME_PREFIX')].logGroupName\" --output text") || exit 1
if [ -n "$LOG_GROUPS" ] && [ "$LOG_GROUPS" != "None" ]; then
    echo "FOUND: $LOG_GROUPS"
    echo "  Note: Low cost (\$0.50/GB), may be kept for audit"
else
    echo "OK"
fi

# Check Secrets Manager secrets
echo -n "Checking Secrets Manager secrets... "
SECRETS=$(aws_check "aws secretsmanager list-secrets --region '$REGION' --query \"SecretList[?contains(Name, '$NAME_PREFIX')].Name\" --output text") || exit 1
if [ -n "$SECRETS" ] && [ "$SECRETS" != "None" ]; then
    echo "FOUND: $SECRETS"
    ISSUES=$((ISSUES + 1))
else
    echo "OK"
fi

echo ""
echo "=== Summary ==="
if [ $ISSUES -eq 0 ]; then
    echo "No billable resources found. Clean!"
    exit 0
else
    echo "Found $ISSUES types of resources still present."
    echo "These may incur costs. Review and remove manually if needed."
    exit 1
fi
