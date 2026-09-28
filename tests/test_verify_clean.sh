#!/bin/bash
# Test verify-clean.sh logic with inline stub functions
# Bash 3.2 compatible

set -e

echo "=== Testing verify-clean.sh core logic ==="
echo ""

# Test the region fallback logic
echo "--- Test: Region fallback to us-east-1 ---"
REGION=""
if [ -z "$REGION" ]; then
    REGION="${AWS_REGION:-}"
fi
if [ -z "$REGION" ]; then
    REGION="${AWS_DEFAULT_REGION:-}"
fi
if [ -z "$REGION" ]; then
    REGION="us-east-1"
fi

if [ "$REGION" = "us-east-1" ]; then
    echo "PASS: Falls back to us-east-1"
else
    echo "FAIL: Expected us-east-1, got: $REGION"
    exit 1
fi
echo ""

# Test exit code handling
echo "--- Test: aws_check handles exit codes ---"
aws_check_test() {
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
        rm -f "$errf"
        return 1
    fi
}

# Test case: command succeeds with empty output
if aws_check_test "echo ''"; then
    if [ -z "$OUTPUT" ]; then
        echo "PASS: Handles empty success output"
    else
        echo "FAIL: OUTPUT should be empty"
        exit 1
    fi
else
    echo "FAIL: Should return 0 for successful command"
    exit 1
fi
echo ""

# Test case: command fails
if ! aws_check_test "exit 255"; then
    echo "PASS: Detects command failure"
else
    echo "FAIL: Should return non-zero for failed command"
    exit 1
fi
echo ""

# Test resource detection logic
echo "--- Test: Resource detection ---"
TEST_OUTPUT="vpc-12345678"
ISSUES=0

if [ -n "$TEST_OUTPUT" ] && [ "$TEST_OUTPUT" != "None" ]; then
    ISSUES=$((ISSUES + 1))
fi

if [ $ISSUES -eq 1 ]; then
    echo "PASS: Detects leftover resources"
else
    echo "FAIL: Should increment ISSUES for non-empty output"
    exit 1
fi
echo ""

# Test clean state detection
echo "--- Test: Clean state detection ---"
TEST_OUTPUT=""
ISSUES=0

if [ -n "$TEST_OUTPUT" ] && [ "$TEST_OUTPUT" != "None" ]; then
    ISSUES=$((ISSUES + 1))
fi

if [ $ISSUES -eq 0 ]; then
    echo "PASS: Recognizes clean state"
else
    echo "FAIL: Should not increment ISSUES for empty output"
    exit 1
fi
echo ""

echo "=== All logic tests passed ==="
