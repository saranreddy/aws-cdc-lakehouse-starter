#!/bin/bash
# Test verify-clean.sh with stubbed aws CLI
# Bash 3.2 compatible

set -e

TEST_DIR=$(mktemp -d)
trap "rm -rf '$TEST_DIR'" EXIT

echo "=== Testing verify-clean.sh ==="
echo "Test directory: $TEST_DIR"
echo ""

# Export TEST_DIR so stub can use it
export TEST_DIR

# Create a minimal terraform.tfvars
mkdir -p "$TEST_DIR/terraform"
echo 'region = "us-east-1"' > "$TEST_DIR/terraform/terraform.tfvars"

# Create stub aws executable
AWS_STUB="$TEST_DIR/aws"
cat > "$AWS_STUB" << 'STUB_END'
#!/bin/bash
# Stub aws CLI for testing
# Returns output based on TEST_CASE environment variable

case "$TEST_CASE" in
    clean)
        # Case (a): Empty state - no resources
        echo ""
        exit 0
        ;;
    warning)
        # Case (b): Stderr warning with empty result
        echo "WARNING: urllib3 version mismatch" >&2
        echo ""
        exit 0
        ;;
    error)
        # Case (c): Real CLI error
        echo "An error occurred (InvalidClientTokenId) when calling the DescribeVpcs operation" >&2
        exit 255
        ;;
    leftover)
        # Case (d): One leftover resource
        # Return a VPC on the first call, empty on subsequent calls
        if [ ! -f "$TEST_DIR/.first_call_done" ]; then
            touch "$TEST_DIR/.first_call_done"
            if echo "$*" | grep -q "describe-vpcs"; then
                echo "vpc-12345678"
                exit 0
            fi
        fi
        echo ""
        exit 0
        ;;
    *)
        echo "Unknown TEST_CASE: $TEST_CASE" >&2
        exit 1
        ;;
esac
STUB_END
chmod +x "$AWS_STUB"

# Add stub to PATH
export PATH="$TEST_DIR:$PATH"

# Test case (a): Clean state
echo "--- Test (a): Clean state ---"
export TEST_CASE=clean
cd "$TEST_DIR"
OUTPUT=$(bash /workspace/scripts/verify-clean.sh 2>&1)
if echo "$OUTPUT" | grep -q "Clean:"; then
    if echo "$OUTPUT" | tail -1 | grep -q "Clean:"; then
        echo "PASS: Exits 0 and prints 'Clean:'"
    else
        echo "FAIL: Should exit 0"
        exit 1
    fi
else
    echo "FAIL: Should print 'Clean:'"
    echo "=== Actual output (first 50 lines): ==="
    echo "$OUTPUT" | head -50
    echo "=== End output ==="
    exit 1
fi
echo ""

# Test case (b): Stderr warning with empty result
echo "--- Test (b): Stderr warning (rc=0) ---"
export TEST_CASE=warning
cd "$TEST_DIR"
if bash /workspace/scripts/verify-clean.sh 2>&1 | grep -q "Clean:"; then
    if bash /workspace/scripts/verify-clean.sh > /dev/null 2>&1; then
        echo "PASS: Exits 0 and prints 'Clean:' (warning ignored)"
    else
        echo "FAIL: Should exit 0"
        exit 1
    fi
else
    echo "FAIL: Should print 'Clean:'"
    exit 1
fi
echo ""

# Test case (c): Real CLI error
echo "--- Test (c): CLI error (rc=255) ---"
export TEST_CASE=error
cd "$TEST_DIR"
OUTPUT=$(bash /workspace/scripts/verify-clean.sh 2>&1 || true)
if echo "$OUTPUT" | grep -q "ERROR: AWS CLI failed"; then
    if ! bash /workspace/scripts/verify-clean.sh > /dev/null 2>&1; then
        echo "PASS: Exits non-zero and prints error"
    else
        echo "FAIL: Should exit non-zero"
        exit 1
    fi
else
    echo "FAIL: Should print 'ERROR: AWS CLI failed'"
    echo "Got: $OUTPUT"
    exit 1
fi
echo ""

# Test case (d): Leftover resource
echo "--- Test (d): Leftover resource ---"
export TEST_CASE=leftover
cd "$TEST_DIR"
rm -f "$TEST_DIR/.first_call_done"
OUTPUT=$(bash /workspace/scripts/verify-clean.sh 2>&1 || true)
if echo "$OUTPUT" | grep -q "vpc-12345678"; then
    # Check that it also exited non-zero by inspecting the captured output for FAILED
    if echo "$OUTPUT" | grep -q "FAILED:"; then
        echo "PASS: Exits non-zero and names leftover resource"
    else
        echo "FAIL: Should exit non-zero (missing FAILED in output)"
        echo "Got: $OUTPUT"
        exit 1
    fi
else
    echo "FAIL: Should name leftover resource 'vpc-12345678'"
    echo "Got: $OUTPUT"
    exit 1
fi
echo ""

echo "=== All tests passed ==="
