#!/bin/bash
# Test verify-clean.sh with stubbed aws and terraform commands
# Bash 3.2 compatible

set -e

# Resolve repo root relative to this script
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)

TEST_DIR=$(mktemp -d)
trap "rm -rf '$TEST_DIR'" EXIT

echo "=== Testing verify-clean.sh with stubs ==="
echo "Test directory: $TEST_DIR"
echo ""

# Export TEST_DIR so stubs can use it
export TEST_DIR

# Create stub terraform
cat > "$TEST_DIR/terraform" << 'TERRAFORM_STUB_END'
#!/bin/bash
# Stub terraform for testing
if [ "$1" = "output" ] && [ "$2" = "-no-color" ] && [ "$3" = "-raw" ] && [ "$4" = "region" ]; then
    case "$TEST_CASE" in
        no-outputs)
            echo "Warning: No outputs found" >&2
            exit 1
            ;;
        *)
            echo "us-west-2"
            exit 0
            ;;
    esac
fi
exit 0
TERRAFORM_STUB_END
chmod +x "$TEST_DIR/terraform"

# Create stub aws
cat > "$TEST_DIR/aws" << 'AWS_STUB_END'
#!/bin/bash
# Stub aws CLI for testing
case "$TEST_CASE" in
    clean)
        # Case (a): Empty results
        echo ""
        exit 0
        ;;
    warning)
        # Case (b): Stderr warning with rc 0 and empty result
        echo "WARNING: urllib3 version mismatch" >&2
        echo ""
        exit 0
        ;;
    error)
        # Case (c): rc 255 with an error on stderr
        echo "An error occurred (InvalidClientTokenId) when calling the DescribeVpcs operation" >&2
        exit 255
        ;;
    leftover)
        # Case (d): One leftover resource (S3 bucket)
        if echo "$*" | grep -q "s3api list-buckets"; then
            echo "cdc-lakehouse-data-abc123"
            exit 0
        fi
        echo ""
        exit 0
        ;;
    no-outputs)
        # Case (e): Uses fallback region
        echo ""
        exit 0
        ;;
    *)
        echo ""
        exit 0
        ;;
esac
AWS_STUB_END
chmod +x "$TEST_DIR/aws"

# Add stubs to PATH
export PATH="$TEST_DIR:$PATH"

# Create minimal terraform directory structure for the script
mkdir -p "$TEST_DIR/tf_dir"
echo 'region = "us-east-1"' > "$TEST_DIR/tf_dir/terraform.tfvars"

# Test case (a): Empty results -> exit 0 and 'Clean'
echo "--- Test (a): Empty results ---"
export TEST_CASE=clean
cd "$TEST_DIR"
OUTPUT=$(bash "$REPO_ROOT/scripts/verify-clean.sh" 2>&1 || true)
if echo "$OUTPUT" | grep -q "Clean:"; then
    if echo "$OUTPUT" | grep -q "Clean: No billable resources found"; then
        echo "PASS: Exits 0 and prints 'Clean'"
    else
        echo "FAIL: Wrong clean message"
        exit 1
    fi
else
    echo "FAIL: Should print 'Clean:'"
    echo "Got: $OUTPUT" | head -20
    exit 1
fi
echo ""

# Test case (b): Stderr warning with rc 0 and empty result -> exit 0 and 'Clean'
echo "--- Test (b): Stderr warning (rc 0, empty result) ---"
export TEST_CASE=warning
cd "$TEST_DIR"
OUTPUT=$(bash "$REPO_ROOT/scripts/verify-clean.sh" 2>&1 || true)
if echo "$OUTPUT" | grep -q "Clean:"; then
    echo "PASS: Exits 0 and prints 'Clean' (warning ignored)"
else
    echo "FAIL: Should print 'Clean:' despite stderr warning"
    echo "Got: $OUTPUT" | head -20
    exit 1
fi
echo ""

# Test case (c): rc 255 with error on stderr -> non-zero exit and error printed
echo "--- Test (c): CLI error (rc 255) ---"
export TEST_CASE=error
cd "$TEST_DIR"
OUTPUT=$(bash "$REPO_ROOT/scripts/verify-clean.sh" 2>&1 || true)
if echo "$OUTPUT" | grep -q "ERROR: AWS CLI failed"; then
    if echo "$OUTPUT" | grep -q "InvalidClientTokenId"; then
        echo "PASS: Exits non-zero and prints error"
    else
        echo "FAIL: Should print the actual error message"
        exit 1
    fi
else
    echo "FAIL: Should print 'ERROR: AWS CLI failed'"
    echo "Got: $OUTPUT" | head -20
    exit 1
fi
echo ""

# Test case (d): One leftover resource -> non-zero exit and name printed
echo "--- Test (d): Leftover resource (S3 bucket) ---"
export TEST_CASE=leftover
cd "$TEST_DIR"
OUTPUT=$(bash "$REPO_ROOT/scripts/verify-clean.sh" 2>&1 || true)
if echo "$OUTPUT" | grep -q "cdc-lakehouse-data-abc123"; then
    if echo "$OUTPUT" | grep -q "FAILED:"; then
        echo "PASS: Exits non-zero and prints resource name"
    else
        echo "FAIL: Should print FAILED"
        exit 1
    fi
else
    echo "FAIL: Should name leftover resource 'cdc-lakehouse-data-abc123'"
    echo "Got: $OUTPUT" | head -20
    exit 1
fi
echo ""

# Test case (e): terraform output fails -> falls back to us-east-1
echo "--- Test (e): No terraform outputs -> us-east-1 fallback ---"
export TEST_CASE=no-outputs
cd "$TEST_DIR"
OUTPUT=$(bash "$REPO_ROOT/scripts/verify-clean.sh" 2>&1 || true)
if echo "$OUTPUT" | grep -q "Region: us-east-1"; then
    echo "PASS: Falls back to us-east-1"
else
    echo "FAIL: Should fall back to us-east-1"
    echo "Got: $OUTPUT" | head -20
    exit 1
fi
echo ""

echo "=== All 5 tests passed ==="
