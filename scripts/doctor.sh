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
if aws sts get-caller-identity >/dev/null 2>&1; then
    CALLER_IDENTITY=$(aws sts get-caller-identity)
    ACCOUNT_ID=$(echo "$CALLER_IDENTITY" | grep -o '"Account": "[^"]*' | cut -d'"' -f4)
    USER_ARN=$(echo "$CALLER_IDENTITY" | grep -o '"Arn": "[^"]*' | cut -d'"' -f4)
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
REQUIRED_TOOLS="terraform aws psql python3"
for tool in $REQUIRED_TOOLS; do
    echo -n "  $tool... "
    if command -v "$tool" >/dev/null 2>&1; then
        VERSION=$($tool --version 2>&1 | head -n 1)
        echo -e "${GREEN}OK${NC} ($VERSION)"
    else
        echo -e "${RED}NOT FOUND${NC}"
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
    QUOTA=$(aws service-quotas get-service-quota \
        --service-code "$service" \
        --quota-code "$quota_code" \
        --region "$REGION" 2>/dev/null | \
        grep -o '"Value": [0-9.]*' | cut -d' ' -f2 || echo "0")
    
    if [ "$QUOTA" = "0" ]; then
        echo -e "${YELLOW}Unable to check${NC}"
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

check_quota "kafka" "L-6C9C37C4" "MSK clusters per region" 1
check_quota "rds" "L-7B6409FD" "DB instances" 1
check_quota "ec2" "L-0EA8095F" "Interface VPC endpoints per VPC" 8
echo ""

# Check Terraform
echo -n "Validating Terraform configuration... "
if cd terraform && terraform init -backend=false >/dev/null 2>&1 && terraform validate >/dev/null 2>&1; then
    echo -e "${GREEN}OK${NC}"
    cd ..
else
    echo -e "${RED}FAILED${NC}"
    ERRORS=$((ERRORS + 1))
    cd ..
fi
echo ""

# Cost estimation
echo "=== Estimated AWS Costs (as of 2026-09-28, $REGION) ==="
echo ""
echo "Based on current AWS pricing:"
echo ""
echo "Compute & Storage:"
echo "  RDS db.t4g.micro (PostgreSQL)           ~\$0.016/hour"
echo "  RDS storage (20 GB gp3)                 ~\$0.003/hour"
echo "  MSK Serverless cluster-hour             ~\$0.750/hour"
echo "  MSK Serverless partition-hours (15)     ~\$0.023/hour"
echo "  MSK Connect (2 MCU-hours)               ~\$0.220/hour"
echo "  EC2 t3.micro bastion                    ~\$0.010/hour"
echo ""
echo "Networking:"
echo "  VPC Interface Endpoints (6 endpoints)   ~\$0.120/hour"
echo "  (2 AZs x \$0.01/hour x 6 endpoints)"
echo ""
echo "Data Transfer & Queries:"
echo "  S3 storage (varies with data)           ~\$0.023/GB/month"
echo "  Athena queries                          ~\$5/TB scanned"
echo "  CloudWatch Logs (minimal)               ~\$0.50/GB ingested"
echo ""
echo "---"
echo "Total estimated hourly cost:              ~\$1.14/hour"
echo "Estimated cost for 1-hour test:           ~\$1.20"
echo ""
echo "Notes:"
echo "  - Pricing from https://aws.amazon.com/pricing/ (verified 2026-09-28)"
echo "  - MSK Serverless: Auto-scaling, no broker management"
echo "  - Cost drops to ~\$0 within minutes after 'make destroy'"
echo "  - Actual costs may vary based on usage and data transfer"
echo ""

# Summary
echo "=== Summary ==="
if [ $ERRORS -gt 0 ]; then
    echo -e "${RED}Found $ERRORS error(s)${NC}"
    echo "Please resolve errors before running 'make apply'"
    exit 1
elif [ $WARNINGS -gt 0 ]; then
    echo -e "${YELLOW}Found $WARNINGS warning(s)${NC}"
    echo "You may proceed with 'make apply'"
else
    echo -e "${GREEN}All checks passed!${NC}"
    echo "Ready to run 'make apply'"
fi
