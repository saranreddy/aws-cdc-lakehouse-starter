#!/bin/bash
set -e

echo "=== Verify Clean Teardown ==="
echo ""

# Get region with proper validation and fallback to us-east-1
REGION=""
if [ -d "terraform" ] && [ -f "terraform/terraform.tfstate" ]; then
    REGION=$(cd terraform && terraform output -raw region 2>/dev/null || true)
fi

# Validate region format
if [ -n "$REGION" ] && ! echo "$REGION" | grep -Eq '^[a-z]{2}(-[a-z]+)+-[0-9]$'; then
    echo "Warning: Invalid region format from terraform: $REGION"
    REGION=""
fi

# Fallback chain with final us-east-1 default
if [ -z "$REGION" ]; then
    REGION="${AWS_REGION:-}"
fi
if [ -z "$REGION" ]; then
    REGION="${AWS_DEFAULT_REGION:-}"
fi
if [ -z "$REGION" ] && [ -f "terraform/terraform.tfvars" ]; then
    REGION=$(grep '^region' terraform/terraform.tfvars 2>/dev/null | cut -d'"' -f2 || true)
fi
if [ -z "$REGION" ]; then
    REGION="us-east-1"
fi

# Final validation
if ! echo "$REGION" | grep -Eq '^[a-z]{2}(-[a-z]+)+-[0-9]$'; then
    echo "Error: Could not determine valid AWS region (got: '$REGION')"
    exit 1
fi

NAME_PREFIX="${1:-cdc-lakehouse}"

echo "Checking for remaining billable resources..."
echo "  Region: $REGION"
echo "  Name prefix: $NAME_PREFIX"
echo ""

ISSUES=0

# Helper function: run AWS CLI with separate stdout/stderr
# Returns rc=0 for success (clean), rc=1 for CLI error, sets $OUTPUT
aws_check() {
    local cmd="$1"
    local errf
    local rc
    errf=$(mktemp)
    
    OUTPUT=$(eval "$cmd" 2>"$errf")
    rc=$?
    
    if [ $rc -eq 0 ]; then
        rm -f "$errf"
        return 0
    else
        echo "ERROR: AWS CLI failed (exit $rc)"
        echo "  Command: $cmd"
        if [ -s "$errf" ]; then
            echo "  Error output:"
            cat "$errf" | sed 's/^/    /'
        fi
        rm -f "$errf"
        return 1
    fi
}

# Check VPCs (needed for ENI lookup)
echo -n "Checking VPCs... "
if aws_check "aws ec2 describe-vpcs --region '$REGION' --filters 'Name=tag:Name,Values=${NAME_PREFIX}-*' --query 'Vpcs[].VpcId' --output text"; then
    if [ -n "$OUTPUT" ] && [ "$OUTPUT" != "None" ]; then
        VPC_ID="$OUTPUT"
        echo "FOUND: $OUTPUT"
        ISSUES=$((ISSUES + 1))
    else
        VPC_ID=""
        echo "OK"
    fi
else
    exit 1
fi

# Check subnets
echo -n "Checking subnets... "
if aws_check "aws ec2 describe-subnets --region '$REGION' --filters 'Name=tag:Name,Values=${NAME_PREFIX}-*' --query 'Subnets[].SubnetId' --output text"; then
    if [ -n "$OUTPUT" ] && [ "$OUTPUT" != "None" ]; then
        echo "FOUND: $OUTPUT"
        ISSUES=$((ISSUES + 1))
    else
        echo "OK"
    fi
else
    exit 1
fi

# Check security groups (needed for ENI lookup)
echo -n "Checking security groups... "
if aws_check "aws ec2 describe-security-groups --region '$REGION' --filters 'Name=tag:Name,Values=${NAME_PREFIX}-*' --query 'SecurityGroups[].GroupId' --output text"; then
    if [ -n "$OUTPUT" ] && [ "$OUTPUT" != "None" ]; then
        SG_IDS="$OUTPUT"
        echo "FOUND: $OUTPUT"
        ISSUES=$((ISSUES + 1))
    else
        SG_IDS=""
        echo "OK"
    fi
else
    exit 1
fi

# Check network interfaces by VPC ID or security group IDs
echo -n "Checking network interfaces... "
ENI_FILTERS=""
if [ -n "$VPC_ID" ]; then
    ENI_FILTERS="Name=vpc-id,Values=$VPC_ID"
elif [ -n "$SG_IDS" ]; then
    ENI_FILTERS="Name=group-id,Values=${SG_IDS// /,}"
fi

if [ -n "$ENI_FILTERS" ]; then
    if aws_check "aws ec2 describe-network-interfaces --region '$REGION' --filters '$ENI_FILTERS' --query 'NetworkInterfaces[].NetworkInterfaceId' --output text"; then
        if [ -n "$OUTPUT" ] && [ "$OUTPUT" != "None" ]; then
            echo "FOUND: $OUTPUT"
            ISSUES=$((ISSUES + 1))
        else
            echo "OK"
        fi
    else
        exit 1
    fi
else
    echo "SKIPPED (no VPC or SG to filter by)"
fi

# Check Elastic IPs
echo -n "Checking Elastic IPs... "
if aws_check "aws ec2 describe-addresses --region '$REGION' --filters 'Name=tag:Name,Values=${NAME_PREFIX}-*' --query 'Addresses[].AllocationId' --output text"; then
    if [ -n "$OUTPUT" ] && [ "$OUTPUT" != "None" ]; then
        echo "FOUND: $OUTPUT"
        ISSUES=$((ISSUES + 1))
    else
        echo "OK"
    fi
else
    exit 1
fi

# Check NAT gateways
echo -n "Checking NAT gateways... "
if aws_check "aws ec2 describe-nat-gateways --region '$REGION' --filter 'Name=tag:Name,Values=${NAME_PREFIX}-*' --query 'NatGateways[?State!=\`deleted\`].NatGatewayId' --output text"; then
    if [ -n "$OUTPUT" ] && [ "$OUTPUT" != "None" ]; then
        echo "FOUND: $OUTPUT"
        ISSUES=$((ISSUES + 1))
    else
        echo "OK"
    fi
else
    exit 1
fi

# Check VPC endpoints (filter out deleted/deleting)
echo -n "Checking VPC endpoints... "
if aws_check "aws ec2 describe-vpc-endpoints --region '$REGION' --filters 'Name=tag:Name,Values=${NAME_PREFIX}-*' --query 'VpcEndpoints[?State!=\`deleted\` && State!=\`deleting\`].VpcEndpointId' --output text"; then
    if [ -n "$OUTPUT" ] && [ "$OUTPUT" != "None" ]; then
        echo "FOUND: $OUTPUT"
        ISSUES=$((ISSUES + 1))
    else
        echo "OK"
    fi
else
    exit 1
fi

# Check RDS instances
echo -n "Checking RDS instances... "
if aws_check "aws rds describe-db-instances --region '$REGION' --query \"DBInstances[?starts_with(DBInstanceIdentifier, '$NAME_PREFIX')].DBInstanceIdentifier\" --output text"; then
    if [ -n "$OUTPUT" ] && [ "$OUTPUT" != "None" ]; then
        DB_IDENTIFIER="$OUTPUT"
        echo "FOUND: $OUTPUT"
        ISSUES=$((ISSUES + 1))
    else
        DB_IDENTIFIER=""
        echo "OK"
    fi
else
    exit 1
fi

# Check RDS parameter groups
echo -n "Checking RDS parameter groups... "
if aws_check "aws rds describe-db-parameter-groups --region '$REGION' --query \"DBParameterGroups[?starts_with(DBParameterGroupName, '$NAME_PREFIX')].DBParameterGroupName\" --output text"; then
    if [ -n "$OUTPUT" ] && [ "$OUTPUT" != "None" ]; then
        echo "FOUND: $OUTPUT"
        ISSUES=$((ISSUES + 1))
    else
        echo "OK"
    fi
else
    exit 1
fi

# Check RDS subnet groups
echo -n "Checking RDS subnet groups... "
if aws_check "aws rds describe-db-subnet-groups --region '$REGION' --query \"DBSubnetGroups[?starts_with(DBSubnetGroupName, '$NAME_PREFIX')].DBSubnetGroupName\" --output text"; then
    if [ -n "$OUTPUT" ] && [ "$OUTPUT" != "None" ]; then
        echo "FOUND: $OUTPUT"
        ISSUES=$((ISSUES + 1))
    else
        echo "OK"
    fi
else
    exit 1
fi

# Check MSK clusters
echo -n "Checking MSK clusters... "
if aws_check "aws kafka list-clusters-v2 --region '$REGION' --query \"ClusterInfoList[?starts_with(ClusterName, '$NAME_PREFIX')].ClusterName\" --output text"; then
    if [ -n "$OUTPUT" ] && [ "$OUTPUT" != "None" ]; then
        echo "FOUND: $OUTPUT"
        ISSUES=$((ISSUES + 1))
    else
        echo "OK"
    fi
else
    exit 1
fi

# Check MSK Connect connectors
echo -n "Checking MSK Connect connectors... "
if aws_check "aws kafkaconnect list-connectors --region '$REGION' --query \"connectors[?starts_with(connectorName, '$NAME_PREFIX')].connectorName\" --output text"; then
    if [ -n "$OUTPUT" ] && [ "$OUTPUT" != "None" ]; then
        echo "FOUND: $OUTPUT"
        ISSUES=$((ISSUES + 1))
    else
        echo "OK"
    fi
else
    exit 1
fi

# Check MSK Connect worker configurations
echo -n "Checking MSK Connect worker configs... "
if aws_check "aws kafkaconnect list-worker-configurations --region '$REGION' --query \"workerConfigurations[?starts_with(name, '$NAME_PREFIX')].name\" --output text"; then
    if [ -n "$OUTPUT" ] && [ "$OUTPUT" != "None" ]; then
        echo "FOUND: $OUTPUT"
        ISSUES=$((ISSUES + 1))
    else
        echo "OK"
    fi
else
    exit 1
fi

# Check MSK Connect custom plugins
echo -n "Checking MSK Connect custom plugins... "
if aws_check "aws kafkaconnect list-custom-plugins --region '$REGION' --query \"customPlugins[?starts_with(name, '$NAME_PREFIX')].name\" --output text"; then
    if [ -n "$OUTPUT" ] && [ "$OUTPUT" != "None" ]; then
        echo "FOUND: $OUTPUT"
        ISSUES=$((ISSUES + 1))
    else
        echo "OK"
    fi
else
    exit 1
fi

# Check S3 buckets
echo -n "Checking S3 buckets... "
if aws_check "aws s3api list-buckets --query \"Buckets[?starts_with(Name, '$NAME_PREFIX')].Name\" --output text"; then
    if [ -n "$OUTPUT" ] && [ "$OUTPUT" != "None" ]; then
        echo "FOUND: $OUTPUT"
        ISSUES=$((ISSUES + 1))
    else
        echo "OK"
    fi
else
    exit 1
fi

# Check Glue databases
echo -n "Checking Glue databases... "
if aws_check "aws glue get-databases --region '$REGION' --query \"DatabaseList[?starts_with(Name, '${NAME_PREFIX//-/_}_')].Name\" --output text"; then
    if [ -n "$OUTPUT" ] && [ "$OUTPUT" != "None" ]; then
        echo "FOUND: $OUTPUT"
        ISSUES=$((ISSUES + 1))
    else
        echo "OK"
    fi
else
    exit 1
fi

# Check IAM roles
echo -n "Checking IAM roles... "
if aws_check "aws iam list-roles --query \"Roles[?starts_with(RoleName, '$NAME_PREFIX')].RoleName\" --output text"; then
    if [ -n "$OUTPUT" ] && [ "$OUTPUT" != "None" ]; then
        echo "FOUND: $OUTPUT"
        ISSUES=$((ISSUES + 1))
    else
        echo "OK"
    fi
else
    exit 1
fi

# Check IAM instance profiles
echo -n "Checking IAM instance profiles... "
if aws_check "aws iam list-instance-profiles --query \"InstanceProfiles[?starts_with(InstanceProfileName, '$NAME_PREFIX')].InstanceProfileName\" --output text"; then
    if [ -n "$OUTPUT" ] && [ "$OUTPUT" != "None" ]; then
        echo "FOUND: $OUTPUT"
        ISSUES=$((ISSUES + 1))
    else
        echo "OK"
    fi
else
    exit 1
fi

# Check EC2 instances
echo -n "Checking EC2 instances... "
if aws_check "aws ec2 describe-instances --region '$REGION' --filters 'Name=tag:Name,Values=${NAME_PREFIX}-*' 'Name=instance-state-name,Values=running,stopped,stopping,pending' --query 'Reservations[].Instances[].InstanceId' --output text"; then
    if [ -n "$OUTPUT" ] && [ "$OUTPUT" != "None" ]; then
        echo "FOUND: $OUTPUT"
        ISSUES=$((ISSUES + 1))
    else
        echo "OK"
    fi
else
    exit 1
fi

# Check Athena workgroups
echo -n "Checking Athena workgroups... "
if aws_check "aws athena list-work-groups --region '$REGION' --query \"WorkGroups[?starts_with(Name, '$NAME_PREFIX')].Name\" --output text"; then
    if [ -n "$OUTPUT" ] && [ "$OUTPUT" != "None" ]; then
        echo "FOUND: $OUTPUT"
        ISSUES=$((ISSUES + 1))
    else
        echo "OK"
    fi
else
    exit 1
fi

# Check CloudWatch log groups - now counts as failure
echo -n "Checking CloudWatch log groups... "
if aws_check "aws logs describe-log-groups --region '$REGION' --log-group-name-prefix '/aws/' --query \"logGroups[?contains(logGroupName, '$NAME_PREFIX')].logGroupName\" --output text"; then
    if [ -n "$OUTPUT" ] && [ "$OUTPUT" != "None" ]; then
        echo "FOUND: $OUTPUT"
        ISSUES=$((ISSUES + 1))
    else
        echo "OK"
    fi
else
    exit 1
fi

# Check Secrets Manager secrets - user-created ones
echo -n "Checking Secrets Manager secrets (user-created)... "
if aws_check "aws secretsmanager list-secrets --region '$REGION' --query \"SecretList[?contains(Name, '$NAME_PREFIX') && !starts_with(Name, 'rds!')].Name\" --output text"; then
    if [ -n "$OUTPUT" ] && [ "$OUTPUT" != "None" ]; then
        echo "FOUND: $OUTPUT"
        ISSUES=$((ISSUES + 1))
    else
        echo "OK"
    fi
else
    exit 1
fi

# Check RDS-managed secrets by tag or description
echo -n "Checking RDS-managed secrets... "
if [ -n "$DB_IDENTIFIER" ]; then
    # Try tag-based lookup first
    if aws_check "aws secretsmanager list-secrets --region '$REGION' --filters Key=tag-key,Values=aws:rds:primaryDBInstanceArn --query \"SecretList[?contains(to_string(Tags), '$DB_IDENTIFIER')].Name\" --output text"; then
        RDS_SECRETS="$OUTPUT"
    else
        exit 1
    fi
    
    # Also check by description pattern (rds!db-xxx format)
    if aws_check "aws secretsmanager list-secrets --region '$REGION' --query \"SecretList[?starts_with(Name, 'rds!') && contains(Description || '', '$DB_IDENTIFIER')].Name\" --output text"; then
        if [ -n "$OUTPUT" ] && [ "$OUTPUT" != "None" ]; then
            RDS_SECRETS="$RDS_SECRETS $OUTPUT"
        fi
    else
        exit 1
    fi
    
    # Deduplicate and report
    RDS_SECRETS=$(echo "$RDS_SECRETS" | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/ $//')
    if [ -n "$RDS_SECRETS" ] && [ "$RDS_SECRETS" != "None" ]; then
        echo "FOUND: $RDS_SECRETS"
        ISSUES=$((ISSUES + 1))
    else
        echo "OK"
    fi
else
    echo "SKIPPED (no DB identifier)"
fi

echo ""
echo "=== Summary ==="
if [ $ISSUES -eq 0 ]; then
    echo "Clean: No billable resources found."
    exit 0
else
    echo "FAILED: Found $ISSUES types of resources still present."
    echo "These may incur costs. Review and remove manually if needed."
    exit 1
fi
