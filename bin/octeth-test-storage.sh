#!/bin/bash
#
# Octeth Storage Connectivity Test Tool
# Tests connectivity to configured cloud storage providers
#
# Author: Octeth Team
# License: MIT
#

set -euo pipefail

# ============================================
# Configuration Loading
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="${PROJECT_ROOT}/config/backup.conf"

# Load configuration
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Configuration file not found: $CONFIG_FILE"
    echo "Please copy config/backup.conf.example to config/backup.conf and configure it"
    exit 2
fi

source "$CONFIG_FILE"

# ============================================
# Global Variables
# ============================================

VERBOSE=false
QUIET=false
TEST_FILE=""
TEST_CONTENT=""
EXIT_CODE=0
TESTS_PASSED=0
TESTS_FAILED=0

# ============================================
# Logging Functions
# ============================================

log() {
    local level="$1"
    shift
    local message="$@"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    if [ "$QUIET" = false ]; then
        echo "[${timestamp}] [${level}] ${message}"
    fi
}

log_info() {
    log "INFO" "$@"
}

log_debug() {
    if [ "$VERBOSE" = true ]; then
        log "DEBUG" "$@"
    fi
}

log_success() {
    if [ "$QUIET" = false ]; then
        echo "[✓] $@"
    fi
}

log_error() {
    if [ "$QUIET" = false ]; then
        echo "[✗] $@" >&2
    fi
}

print_header() {
    if [ "$QUIET" = false ]; then
        echo "========================================"
        echo "$@"
        echo "========================================"
    fi
}

# ============================================
# Helper Functions
# ============================================

create_test_file() {
    local timestamp=$(date +%s)
    TEST_FILE=".octeth-storage-test-${timestamp}.txt"
    TEST_CONTENT="Octeth Backup Storage Test - $(date '+%Y-%m-%d %H:%M:%S')"

    log_debug "Creating test file: ${TEST_FILE}"
    echo "${TEST_CONTENT}" > "/tmp/${TEST_FILE}"
}

cleanup_test_file() {
    if [ -n "${TEST_FILE}" ] && [ -f "/tmp/${TEST_FILE}" ]; then
        log_debug "Removing local test file: /tmp/${TEST_FILE}"
        rm -f "/tmp/${TEST_FILE}"
    fi
}

check_tool_installed() {
    local tool="$1"
    local package_name="${2:-$1}"

    if ! command -v "$tool" &> /dev/null; then
        log_error "${tool} not found"
        echo "    → Please install ${package_name}"
        return 1
    fi

    local version=$(${tool} --version 2>&1 | head -n 1 || echo "unknown")
    log_debug "${tool} version: ${version}"
    log_success "${tool} found: ${version}"
    return 0
}

# ============================================
# S3 Test Functions
# ============================================

test_s3_with_aws_cli() {
    local test_path="${S3_PREFIX}/test/${TEST_FILE}"
    local s3_uri="s3://${S3_BUCKET}/${test_path}"

    log_info "Testing S3 connectivity using AWS CLI"

    # Check AWS CLI installation
    if ! check_tool_installed "aws" "AWS CLI"; then
        echo "    → Install: https://aws.amazon.com/cli/"
        return 1
    fi

    # Set credentials
    export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID}"
    export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY}"

    log_debug "AWS_ACCESS_KEY_ID: ${AWS_ACCESS_KEY_ID:0:4}****************"

    # Test credentials
    log_debug "Testing AWS credentials..."
    if ! aws sts get-caller-identity --region "${S3_REGION}" &>/dev/null; then
        log_error "AWS authentication failed"
        echo "    → Check AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY in config/.env"
        return 1
    fi
    log_success "AWS credentials configured"

    # Test bucket access
    log_debug "Testing bucket access: s3://${S3_BUCKET}/${S3_PREFIX}/"
    if ! aws s3 ls "s3://${S3_BUCKET}/${S3_PREFIX}/" --region "${S3_REGION}" &>/dev/null; then
        log_error "Bucket not accessible"
        echo "    → Bucket: s3://${S3_BUCKET}"
        echo "    → Verify S3_BUCKET in config/.env"
        echo "    → Check IAM permissions: s3:ListBucket"
        return 1
    fi
    log_success "Bucket accessible: s3://${S3_BUCKET}/${S3_PREFIX}/"

    # Test write permissions
    log_debug "Testing write permissions: ${s3_uri}"
    local file_size=$(stat -f%z "/tmp/${TEST_FILE}" 2>/dev/null || stat -c%s "/tmp/${TEST_FILE}" 2>/dev/null)
    if ! aws s3 cp "/tmp/${TEST_FILE}" "${s3_uri}" --region "${S3_REGION}" --storage-class "${S3_STORAGE_CLASS}" &>/dev/null; then
        log_error "Write permission denied"
        echo "    → Check IAM permissions: s3:PutObject"
        return 1
    fi
    log_success "Write test passed (uploaded ${file_size} bytes)"

    # Test read permissions
    log_debug "Testing read permissions: ${s3_uri}"
    if ! aws s3 cp "${s3_uri}" - --region "${S3_REGION}" &>/dev/null; then
        log_error "Read permission denied"
        echo "    → Check IAM permissions: s3:GetObject"
        aws s3 rm "${s3_uri}" --region "${S3_REGION}" &>/dev/null || true
        return 1
    fi
    log_success "Read test passed (downloaded ${file_size} bytes)"

    # Test delete permissions
    log_debug "Testing delete permissions: ${s3_uri}"
    if ! aws s3 rm "${s3_uri}" --region "${S3_REGION}" &>/dev/null; then
        log_error "Delete permission denied"
        echo "    → Check IAM permissions: s3:DeleteObject"
        echo "    → Warning: Test file left at ${s3_uri}"
        return 1
    fi
    log_success "Delete test passed"

    # Verify storage class
    log_debug "Verifying storage class: ${S3_STORAGE_CLASS}"
    local valid_classes="STANDARD REDUCED_REDUNDANCY STANDARD_IA ONEZONE_IA INTELLIGENT_TIERING GLACIER DEEP_ARCHIVE GLACIER_IR"
    if [[ ! " ${valid_classes} " =~ " ${S3_STORAGE_CLASS} " ]]; then
        log_error "Invalid storage class: ${S3_STORAGE_CLASS}"
        echo "    → Valid classes: ${valid_classes}"
        return 1
    fi
    log_success "Storage class valid: ${S3_STORAGE_CLASS}"

    return 0
}

test_s3_with_rclone() {
    local test_path="${S3_PREFIX}/test/${TEST_FILE}"
    local rclone_uri="${RCLONE_REMOTE}:${S3_BUCKET}/${test_path}"

    log_info "Testing S3 connectivity using rclone"

    # Check rclone installation
    if ! check_tool_installed "rclone" "rclone"; then
        echo "    → Install: https://rclone.org/install/"
        return 1
    fi

    # Test remote config
    log_debug "Testing rclone remote: ${RCLONE_REMOTE}"
    if ! rclone lsd "${RCLONE_REMOTE}:${S3_BUCKET}/${S3_PREFIX}/" &>/dev/null; then
        log_error "Remote not accessible"
        echo "    → Configure rclone: rclone config"
        echo "    → Verify RCLONE_REMOTE in config/.env"
        return 1
    fi
    log_success "Remote accessible: ${RCLONE_REMOTE}:${S3_BUCKET}/${S3_PREFIX}/"

    # Test write permissions
    log_debug "Testing write permissions: ${rclone_uri}"
    local file_size=$(stat -f%z "/tmp/${TEST_FILE}" 2>/dev/null || stat -c%s "/tmp/${TEST_FILE}" 2>/dev/null)
    if ! rclone copy "/tmp/${TEST_FILE}" "${RCLONE_REMOTE}:${S3_BUCKET}/${S3_PREFIX}/test/" &>/dev/null; then
        log_error "Write permission denied"
        return 1
    fi
    log_success "Write test passed (uploaded ${file_size} bytes)"

    # Test read permissions
    log_debug "Testing read permissions: ${rclone_uri}"
    if ! rclone cat "${rclone_uri}" &>/dev/null; then
        log_error "Read permission denied"
        rclone delete "${rclone_uri}" &>/dev/null || true
        return 1
    fi
    log_success "Read test passed (downloaded ${file_size} bytes)"

    # Test delete permissions
    log_debug "Testing delete permissions: ${rclone_uri}"
    if ! rclone delete "${rclone_uri}" &>/dev/null; then
        log_error "Delete permission denied"
        echo "    → Warning: Test file left at ${rclone_uri}"
        return 1
    fi
    log_success "Delete test passed"

    return 0
}

test_s3_connectivity() {
    print_header "Testing AWS S3 Storage"

    # Check if S3 is configured
    if [ -z "${S3_BUCKET:-}" ]; then
        log_error "S3_BUCKET not configured in config/.env"
        return 1
    fi

    log_info "Bucket: s3://${S3_BUCKET}/${S3_PREFIX}"
    log_info "Region: ${S3_REGION}"
    log_info "Storage Class: ${S3_STORAGE_CLASS}"
    log_info "Upload Tool: ${S3_UPLOAD_TOOL}"
    echo ""

    # Determine which tool to use
    local tool="${S3_UPLOAD_TOOL:-awscli}"

    case "$tool" in
        awscli)
            test_s3_with_aws_cli
            return $?
            ;;
        rclone)
            test_s3_with_rclone
            return $?
            ;;
        *)
            log_error "Unknown S3_UPLOAD_TOOL: ${tool}"
            echo "    → Valid options: awscli, rclone"
            return 1
            ;;
    esac
}

# ============================================
# GCS Test Functions
# ============================================

test_gcs_with_gsutil() {
    local test_path="${GCS_PREFIX}/test/${TEST_FILE}"
    local gcs_uri="gs://${GCS_BUCKET}/${test_path}"

    log_info "Testing GCS connectivity using gsutil"

    # Check gsutil installation
    if ! check_tool_installed "gsutil" "Google Cloud SDK"; then
        echo "    → Install: https://cloud.google.com/sdk/install"
        return 1
    fi

    # Set credentials if provided
    if [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then
        export GOOGLE_APPLICATION_CREDENTIALS="${GOOGLE_APPLICATION_CREDENTIALS}"
        log_debug "Using credentials from: ${GOOGLE_APPLICATION_CREDENTIALS}"
    fi

    # Test bucket access
    log_debug "Testing bucket access: gs://${GCS_BUCKET}/${GCS_PREFIX}/"
    if ! gsutil ls "gs://${GCS_BUCKET}/${GCS_PREFIX}/" &>/dev/null; then
        log_error "Bucket not accessible"
        echo "    → Bucket: gs://${GCS_BUCKET}"
        echo "    → Verify GCS_BUCKET in config/.env"
        echo "    → Check IAM permissions: storage.objects.list"
        return 1
    fi
    log_success "Bucket accessible: gs://${GCS_BUCKET}/${GCS_PREFIX}/"

    # Test write permissions
    log_debug "Testing write permissions: ${gcs_uri}"
    local file_size=$(stat -f%z "/tmp/${TEST_FILE}" 2>/dev/null || stat -c%s "/tmp/${TEST_FILE}" 2>/dev/null)
    if ! gsutil -h "x-goog-storage-class:${GCS_STORAGE_CLASS}" cp "/tmp/${TEST_FILE}" "${gcs_uri}" &>/dev/null; then
        log_error "Write permission denied"
        echo "    → Check IAM permissions: storage.objects.create"
        return 1
    fi
    log_success "Write test passed (uploaded ${file_size} bytes)"

    # Test read permissions
    log_debug "Testing read permissions: ${gcs_uri}"
    if ! gsutil cat "${gcs_uri}" &>/dev/null; then
        log_error "Read permission denied"
        echo "    → Check IAM permissions: storage.objects.get"
        gsutil rm "${gcs_uri}" &>/dev/null || true
        return 1
    fi
    log_success "Read test passed (downloaded ${file_size} bytes)"

    # Test delete permissions
    log_debug "Testing delete permissions: ${gcs_uri}"
    if ! gsutil rm "${gcs_uri}" &>/dev/null; then
        log_error "Delete permission denied"
        echo "    → Check IAM permissions: storage.objects.delete"
        echo "    → Warning: Test file left at ${gcs_uri}"
        return 1
    fi
    log_success "Delete test passed"

    # Verify storage class
    log_debug "Verifying storage class: ${GCS_STORAGE_CLASS}"
    local valid_classes="STANDARD NEARLINE COLDLINE ARCHIVE"
    if [[ ! " ${valid_classes} " =~ " ${GCS_STORAGE_CLASS} " ]]; then
        log_error "Invalid storage class: ${GCS_STORAGE_CLASS}"
        echo "    → Valid classes: ${valid_classes}"
        return 1
    fi
    log_success "Storage class valid: ${GCS_STORAGE_CLASS}"

    return 0
}

test_gcs_with_rclone() {
    local test_path="${GCS_PREFIX}/test/${TEST_FILE}"
    local rclone_uri="${GCS_RCLONE_REMOTE}:${GCS_BUCKET}/${test_path}"

    log_info "Testing GCS connectivity using rclone"

    # Check rclone installation
    if ! check_tool_installed "rclone" "rclone"; then
        echo "    → Install: https://rclone.org/install/"
        return 1
    fi

    # Test remote config
    log_debug "Testing rclone remote: ${GCS_RCLONE_REMOTE}"
    if ! rclone lsd "${GCS_RCLONE_REMOTE}:${GCS_BUCKET}/${GCS_PREFIX}/" &>/dev/null; then
        log_error "Remote not accessible"
        echo "    → Configure rclone: rclone config"
        echo "    → Verify GCS_RCLONE_REMOTE in config/.env"
        return 1
    fi
    log_success "Remote accessible: ${GCS_RCLONE_REMOTE}:${GCS_BUCKET}/${GCS_PREFIX}/"

    # Test write permissions
    log_debug "Testing write permissions: ${rclone_uri}"
    local file_size=$(stat -f%z "/tmp/${TEST_FILE}" 2>/dev/null || stat -c%s "/tmp/${TEST_FILE}" 2>/dev/null)
    if ! rclone copy "/tmp/${TEST_FILE}" "${GCS_RCLONE_REMOTE}:${GCS_BUCKET}/${GCS_PREFIX}/test/" &>/dev/null; then
        log_error "Write permission denied"
        return 1
    fi
    log_success "Write test passed (uploaded ${file_size} bytes)"

    # Test read permissions
    log_debug "Testing read permissions: ${rclone_uri}"
    if ! rclone cat "${rclone_uri}" &>/dev/null; then
        log_error "Read permission denied"
        rclone delete "${rclone_uri}" &>/dev/null || true
        return 1
    fi
    log_success "Read test passed (downloaded ${file_size} bytes)"

    # Test delete permissions
    log_debug "Testing delete permissions: ${rclone_uri}"
    if ! rclone delete "${rclone_uri}" &>/dev/null; then
        log_error "Delete permission denied"
        echo "    → Warning: Test file left at ${rclone_uri}"
        return 1
    fi
    log_success "Delete test passed"

    return 0
}

test_gcs_connectivity() {
    print_header "Testing Google Cloud Storage"

    # Check if GCS is configured
    if [ -z "${GCS_BUCKET:-}" ]; then
        log_error "GCS_BUCKET not configured in config/.env"
        return 1
    fi

    log_info "Bucket: gs://${GCS_BUCKET}/${GCS_PREFIX}"
    log_info "Storage Class: ${GCS_STORAGE_CLASS}"
    log_info "Upload Tool: ${GCS_UPLOAD_TOOL}"
    echo ""

    # Determine which tool to use
    local tool="${GCS_UPLOAD_TOOL:-gsutil}"

    case "$tool" in
        gsutil)
            test_gcs_with_gsutil
            return $?
            ;;
        rclone)
            test_gcs_with_rclone
            return $?
            ;;
        *)
            log_error "Unknown GCS_UPLOAD_TOOL: ${tool}"
            echo "    → Valid options: gsutil, rclone"
            return 1
            ;;
    esac
}

# ============================================
# R2 Test Functions
# ============================================

test_r2_with_aws_cli() {
    local test_path="${R2_PREFIX}/test/${TEST_FILE}"
    local r2_uri="s3://${R2_BUCKET}/${test_path}"
    local r2_endpoint="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"

    log_info "Testing R2 connectivity using AWS CLI"

    # Check AWS CLI installation
    if ! check_tool_installed "aws" "AWS CLI"; then
        echo "    → Install: https://aws.amazon.com/cli/"
        return 1
    fi

    # Set R2 credentials
    export AWS_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID}"
    export AWS_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY}"

    log_debug "R2_ACCESS_KEY_ID: ${R2_ACCESS_KEY_ID:0:4}****************"
    log_debug "R2 Endpoint: ${r2_endpoint}"

    # Test bucket access
    log_debug "Testing bucket access: ${r2_uri}"
    if ! aws s3 ls "s3://${R2_BUCKET}/${R2_PREFIX}/" --endpoint-url "${r2_endpoint}" &>/dev/null; then
        log_error "Bucket not accessible"
        echo "    → Bucket: ${r2_uri}"
        echo "    → Endpoint: ${r2_endpoint}"
        echo "    → Verify R2_BUCKET and R2_ACCOUNT_ID in config/.env"
        echo "    → Check R2 API token permissions"
        return 1
    fi
    log_success "Bucket accessible: ${r2_uri}"

    # Test write permissions
    log_debug "Testing write permissions: ${r2_uri}"
    local file_size=$(stat -f%z "/tmp/${TEST_FILE}" 2>/dev/null || stat -c%s "/tmp/${TEST_FILE}" 2>/dev/null)
    if ! aws s3 cp "/tmp/${TEST_FILE}" "${r2_uri}" --endpoint-url "${r2_endpoint}" &>/dev/null; then
        log_error "Write permission denied"
        echo "    → Check R2 API token permissions"
        return 1
    fi
    log_success "Write test passed (uploaded ${file_size} bytes)"

    # Test read permissions
    log_debug "Testing read permissions: ${r2_uri}"
    if ! aws s3 cp "${r2_uri}" - --endpoint-url "${r2_endpoint}" &>/dev/null; then
        log_error "Read permission denied"
        aws s3 rm "${r2_uri}" --endpoint-url "${r2_endpoint}" &>/dev/null || true
        return 1
    fi
    log_success "Read test passed (downloaded ${file_size} bytes)"

    # Test delete permissions
    log_debug "Testing delete permissions: ${r2_uri}"
    if ! aws s3 rm "${r2_uri}" --endpoint-url "${r2_endpoint}" &>/dev/null; then
        log_error "Delete permission denied"
        echo "    → Warning: Test file left at ${r2_uri}"
        return 1
    fi
    log_success "Delete test passed"

    return 0
}

test_r2_with_rclone() {
    local test_path="${R2_PREFIX}/test/${TEST_FILE}"
    local rclone_uri="${R2_RCLONE_REMOTE}:${R2_BUCKET}/${test_path}"

    log_info "Testing R2 connectivity using rclone"

    # Check rclone installation
    if ! check_tool_installed "rclone" "rclone"; then
        echo "    → Install: https://rclone.org/install/"
        return 1
    fi

    # Test remote config
    log_debug "Testing rclone remote: ${R2_RCLONE_REMOTE}"
    if ! rclone lsd "${R2_RCLONE_REMOTE}:${R2_BUCKET}/${R2_PREFIX}/" &>/dev/null; then
        log_error "Remote not accessible"
        echo "    → Configure rclone: rclone config"
        echo "    → Verify R2_RCLONE_REMOTE in config/.env"
        return 1
    fi
    log_success "Remote accessible: ${R2_RCLONE_REMOTE}:${R2_BUCKET}/${R2_PREFIX}/"

    # Test write permissions
    log_debug "Testing write permissions: ${rclone_uri}"
    local file_size=$(stat -f%z "/tmp/${TEST_FILE}" 2>/dev/null || stat -c%s "/tmp/${TEST_FILE}" 2>/dev/null)
    if ! rclone copy "/tmp/${TEST_FILE}" "${R2_RCLONE_REMOTE}:${R2_BUCKET}/${R2_PREFIX}/test/" &>/dev/null; then
        log_error "Write permission denied"
        return 1
    fi
    log_success "Write test passed (uploaded ${file_size} bytes)"

    # Test read permissions
    log_debug "Testing read permissions: ${rclone_uri}"
    if ! rclone cat "${rclone_uri}" &>/dev/null; then
        log_error "Read permission denied"
        rclone delete "${rclone_uri}" &>/dev/null || true
        return 1
    fi
    log_success "Read test passed (downloaded ${file_size} bytes)"

    # Test delete permissions
    log_debug "Testing delete permissions: ${rclone_uri}"
    if ! rclone delete "${rclone_uri}" &>/dev/null; then
        log_error "Delete permission denied"
        echo "    → Warning: Test file left at ${rclone_uri}"
        return 1
    fi
    log_success "Delete test passed"

    return 0
}

test_r2_connectivity() {
    print_header "Testing Cloudflare R2 Storage"

    # Check if R2 is configured
    if [ -z "${R2_BUCKET:-}" ] || [ -z "${R2_ACCOUNT_ID:-}" ]; then
        log_error "R2_BUCKET or R2_ACCOUNT_ID not configured in config/.env"
        return 1
    fi

    log_info "Bucket: ${R2_BUCKET}/${R2_PREFIX}"
    log_info "Account ID: ${R2_ACCOUNT_ID}"
    log_info "Upload Tool: ${R2_UPLOAD_TOOL}"
    echo ""

    # Determine which tool to use
    local tool="${R2_UPLOAD_TOOL:-awscli}"

    case "$tool" in
        awscli)
            test_r2_with_aws_cli
            return $?
            ;;
        rclone)
            test_r2_with_rclone
            return $?
            ;;
        *)
            log_error "Unknown R2_UPLOAD_TOOL: ${tool}"
            echo "    → Valid options: awscli, rclone"
            return 1
            ;;
    esac
}

# ============================================
# Main Test Orchestration
# ============================================

usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Tests connectivity to configured cloud storage providers.

OPTIONS:
    -v, --verbose       Enable verbose output (detailed logging)
    -q, --quiet         Quiet mode (only show PASS/FAIL)
    -h, --help          Show this help message

EXAMPLES:
    # Test configured storage provider
    $(basename "$0")

    # Verbose output with detailed logs
    $(basename "$0") -v

    # Quiet mode for scripting
    $(basename "$0") -q && echo "Storage ready"

EXIT CODES:
    0    All tests passed
    1    One or more tests failed
    2    Configuration error
    3    Tool not installed

For more information, see README.md
EOF
}

main() {
    # Parse command-line arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -q|--quiet)
                QUIET=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                usage
                exit 2
                ;;
        esac
    done

    # Print header
    if [ "$QUIET" = false ]; then
        print_header "Octeth Storage Connectivity Test"
        log_info "Cloud storage provider: ${CLOUD_STORAGE_PROVIDER}"
        echo ""
    fi

    # Create test file
    create_test_file

    # Run tests based on provider
    case "${CLOUD_STORAGE_PROVIDER}" in
        s3)
            if test_s3_connectivity; then
                TESTS_PASSED=$((TESTS_PASSED + 1))
            else
                TESTS_FAILED=$((TESTS_FAILED + 1))
                EXIT_CODE=1
            fi
            ;;
        gcs)
            if test_gcs_connectivity; then
                TESTS_PASSED=$((TESTS_PASSED + 1))
            else
                TESTS_FAILED=$((TESTS_FAILED + 1))
                EXIT_CODE=1
            fi
            ;;
        r2)
            if test_r2_connectivity; then
                TESTS_PASSED=$((TESTS_PASSED + 1))
            else
                TESTS_FAILED=$((TESTS_FAILED + 1))
                EXIT_CODE=1
            fi
            ;;
        none)
            if [ "$QUIET" = false ]; then
                echo ""
                log_info "Cloud storage is disabled (CLOUD_STORAGE_PROVIDER=none)"
                log_info "To test cloud storage, set CLOUD_STORAGE_PROVIDER to: s3, gcs, or r2"
                echo ""
            fi
            ;;
        *)
            log_error "Unknown cloud storage provider: ${CLOUD_STORAGE_PROVIDER}"
            echo "    → Valid options: s3, gcs, r2, none"
            EXIT_CODE=2
            ;;
    esac

    # Cleanup
    cleanup_test_file

    # Print summary
    if [ "$QUIET" = true ]; then
        if [ $EXIT_CODE -eq 0 ] && [ "${CLOUD_STORAGE_PROVIDER}" != "none" ]; then
            echo "PASS"
        elif [ "${CLOUD_STORAGE_PROVIDER}" = "none" ]; then
            echo "SKIP"
        else
            echo "FAIL"
        fi
    else
        echo ""
        if [ $TESTS_FAILED -eq 0 ] && [ "${CLOUD_STORAGE_PROVIDER}" != "none" ]; then
            print_header "All tests passed! ✓"
        elif [ "${CLOUD_STORAGE_PROVIDER}" = "none" ]; then
            print_header "Cloud storage testing skipped"
        else
            print_header "Tests failed! ✗"
            echo "Passed: ${TESTS_PASSED}"
            echo "Failed: ${TESTS_FAILED}"
            echo ""
        fi
    fi

    exit $EXIT_CODE
}

# ============================================
# Trap for cleanup on exit
# ============================================

trap cleanup_test_file EXIT INT TERM

# ============================================
# Execute main function
# ============================================

main "$@"
