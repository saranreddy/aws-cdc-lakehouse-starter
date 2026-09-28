#!/bin/bash
set -e

echo "=== Pre-flight Checks ==="
echo ""

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ERRORS=0
WARNINGS=0

# Check AWS credentials
echo -n "Checking AWS credentials... "
if CALLER_IDENTITY=$(aws sts get-caller-identity --query '{Account:Account,Arn:Arn}' --output text 2>/dev/null); then
    ACCOUNT_ID=$(echo "$CALLER_IDENTITY" | awk '{print $1}')
    USER_ARN=$(echo "$CALLER_IDENTITY" | awk '{$1=""; print $0}' | xargs)
    echo -e "${GREEN}OK${NC}"
    echo "  Account: $ACCOUNT_ID"
    echo "  Identity: $USER_ARN"
else
    echo -e "${RED}FAILED${NC}"
    echo "  Please configure AWS credentials"
    ERRORS=$((ERRORS + 1))
fi
echo ""

# Check AWS region
echo -n "Checking AWS region... "
REGION=$(aws configure get region 2>/dev/null || echo "")
if [ -z "$REGION" ]; then
    REGION="us-east-1"
    echo -e "${YELLOW}Not set, defaulting to us-east-1${NC}"
    WARNINGS=$((WARNINGS + 1))
else
    echo -e "${GREEN}$REGION${NC}"
fi
echo ""

# Check required tools
echo "Checking required tools:"
REQUIRED_TOOLS="terraform aws psql python3 curl shasum zip session-manager-plugin"
for tool in $REQUIRED_TOOLS; do
    echo -n "  $tool... "
    if command -v "$tool" >/dev/null 2>&1; then
        VERSION=$($tool --version 2>&1 | head -n 1 || echo "installed")
        echo -e "${GREEN}OK${NC} ($VERSION)"
    else
        echo -e "${RED}NOT FOUND${NC}"
        if [ "$tool" = "session-manager-plugin" ]; then
            echo "    Install: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html"
        fi
        ERRORS=$((ERRORS + 1))
    fi
done
echo ""

# Check Python packages
echo "Checking Python packages:"
REQUIRED_PACKAGES="boto3 psycopg2"
for pkg in $REQUIRED_PACKAGES; do
    echo -n "  $pkg... "
    if python3 -c "import $pkg" 2>/dev/null; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${YELLOW}NOT FOUND${NC} (install with: pip3 install $pkg)"
        WARNINGS=$((WARNINGS + 1))
    fi
done
echo ""

# Check service quotas
echo "Checking relevant service quotas:"
check_quota() {
    local service=$1
    local quota_code=$2
    local quota_name=$3
    local required=$4
    
    echo -n "  $quota_name... "
    
    # Get quota value with explicit error handling
    QUOTA=$(aws service-quotas get-service-quota \
        --service-code "$service" \
        --quota-code "$quota_code" \
        --region "$REGION" \
        --query 'Quota.Value' \
        --output text 2>/dev/null || echo "0")
    
    if [ "$QUOTA" = "0" ] || [ -z "$QUOTA" ]; then
        echo -e "${YELLOW}Unable to check${NC}"
        WARNINGS=$((WARNINGS + 1))
    else
        QUOTA_INT=$(echo "$QUOTA" | cut -d. -f1)
        if [ "$QUOTA_INT" -ge "$required" ]; then
            echo -e "${GREEN}$QUOTA_INT (need $required)${NC}"
        else
            echo -e "${RED}$QUOTA_INT (need $required)${NC}"
            ERRORS=$((ERRORS + 1))
        fi
    fi
}

# Verified quota codes (2026-09-28)
check_quota "kafka" "L-6C9C37C4" "MSK clusters per region" 1
check_quota "rds" "L-7B6409FD" "DB instances" 1
check_quota "vpc" "L-29B6F2EB" "Interface VPC endpoints per VPC" 8 || QUOTA_WARNINGS=$((QUOTA_WARNINGS + 1))
check_quota "ec2" "L-1216C47A" "Running On-Demand Standard instances" 1
echo ""

# Check Terraform
echo -n "Validating Terraform configuration... "
if cd terraform && terraform init -backend=false >/dev/null 2>&1 && terraform validate >/dev/null 2>&1; then
    echo -e "${GREEN}OK${NC}"
    cd ..
else
    echo -e "${RED}FAILED${NC}"
    ERRORS=$((ERRORS + 1))
    cd .. 2>/dev/null || true
fi
echo ""

# Cost estimation
echo "=== Estimated AWS Costs (as of 2026-09-28, $REGION) ==="
echo ""
echo "Based on current AWS pricing (verified 2026-09-28):"
echo ""
echo "Compute & Storage:"
echo "  RDS db.t4g.micro (PostgreSQL)           ~\$0.016/hour"
echo "  RDS storage (20 GB gp3)                 ~\$0.003/hour"
echo "  MSK Serverless cluster-hour             ~\$0.750/hour"
echo "  MSK Serverless partition-hours (~15)    ~\$0.023/hour"
echo "  MSK Connect (2 MCU-hours)               ~\$0.220/hour"
echo "  EC2 t3.micro bastion                    ~\$0.010/hour"
echo "  Public IPv4 address                     ~\$0.005/hour"
echo ""
echo "Networking:"
echo "  VPC Interface Endpoints (6 x 2 AZs)     ~\$0.120/hour"
echo ""
echo "Data Transfer & Queries:"
echo "  S3 storage (varies with data)           ~\$0.023/GB/month"
echo "  Athena queries                          ~\$5/TB scanned"
echo "  CloudWatch Logs (minimal)               ~\$0.50/GB ingested"
echo ""
echo "---"
echo "Total estimated hourly cost:              ~\$1.15/hour"
echo "Estimated cost for 1-hour test:           ~\$1.17-1.20"
echo ""
echo "Notes:"
echo "  - MSK Serverless: \$0.75/cluster-hr + \$0.0015/partition-hr"
echo "  - MSK Connect: \$0.11/MCU-hr x 2 MCUs = \$0.22/hr"
echo "  - Partitions: Estimated ~10 (9 data topics + 1 control + internal topics)"
echo "  - Pricing: https://aws.amazon.com/pricing/ (verified 2026-09-28)"
echo "  - Cost drops to ~\$0 within minutes after 'make down'"
echo ""

# Summary
echo "=== Summary ==="
if [ $ERRORS -gt 0 ]; then
    echo -e "${RED}Found $ERRORS error(s)${NC}"
    echo "Please resolve errors before running 'make up'"
    exit 1
elif [ $WARNINGS -gt 0 ]; then
    echo -e "${YELLOW}Found $WARNINGS warning(s)${NC}"
    echo "You may proceed with 'make up'"
else
    echo -e "${GREEN}All checks passed!${NC}"
    echo "Ready to run 'make up'"
fi
