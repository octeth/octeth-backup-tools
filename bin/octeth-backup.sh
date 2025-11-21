#!/bin/bash
#
# Octeth MySQL Backup Tool
# Using Percona XtraBackup for hot, zero-downtime backups
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
    exit 1
fi

source "$CONFIG_FILE"

# ============================================
# Global Variables
# ============================================

BACKUP_START_TIME=$(date +%s)
BACKUP_TIMESTAMP=$(date +"${DATE_FORMAT}")
BACKUP_NAME="${BACKUP_PREFIX}-${BACKUP_TIMESTAMP}"
BACKUP_TYPE=""
ERROR_LOG=""
EXIT_CODE=0

# ============================================
# Logging Functions
# ============================================

log() {
    local level="$1"
    shift
    local message="$@"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${level}] ${message}" | tee -a "${LOG_FILE}"
}

log_info() {
    log "INFO" "$@"
}

log_error() {
    log "ERROR" "$@"
    ERROR_LOG="${ERROR_LOG}\n$@"
}

log_warn() {
    log "WARN" "$@"
}

log_success() {
    log "SUCCESS" "$@"
}

# ============================================
# Cleanup Functions
# ============================================

cleanup() {
    local exit_code=$?

    if [ -f "${LOCK_FILE}" ]; then
        log_info "Removing lock file"
        rm -f "${LOCK_FILE}"
    fi

    if [ -d "${TEMP_DIR}" ]; then
        log_info "Cleaning up temporary directory"
        rm -rf "${TEMP_DIR}"
    fi

    return $exit_code
}

trap cleanup EXIT INT TERM

# ============================================
# Pre-flight Checks
# ============================================

check_lock_file() {
    if [ -f "${LOCK_FILE}" ]; then
        local lock_pid=$(cat "${LOCK_FILE}" 2>/dev/null || echo "")

        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
            log_error "Another backup is already running (PID: $lock_pid)"
            exit 1
        else
            log_warn "Stale lock file found, removing it"
            rm -f "${LOCK_FILE}"
        fi
    fi

    echo $$ > "${LOCK_FILE}"
    log_info "Lock file created: ${LOCK_FILE}"
}

check_xtrabackup() {
    if ! command -v ${XTRABACKUP_BIN} &> /dev/null; then
        log_error "XtraBackup not found. Please install Percona XtraBackup 8.0"
        log_error "Installation: https://www.percona.com/downloads/Percona-XtraBackup-LATEST/"
        exit 1
    fi

    local xb_version=$(${XTRABACKUP_BIN} --version 2>&1 | head -n1)
    log_info "Using XtraBackup: ${xb_version}"
}

check_disk_space() {
    local backup_dir_parent=$(dirname "${BACKUP_DIR}")

    # Create backup directory if it doesn't exist
    mkdir -p "${BACKUP_DIR}"

    # Check disk usage
    local disk_usage=$(df -h "${backup_dir_parent}" | awk 'NR==2 {print $5}' | sed 's/%//')
    local free_space_gb=$(df -BG "${backup_dir_parent}" | awk 'NR==2 {print $4}' | sed 's/G//')

    if [ "$disk_usage" -gt "$MAX_DISK_USAGE" ]; then
        log_error "Disk usage is ${disk_usage}% (threshold: ${MAX_DISK_USAGE}%)"
        exit 1
    fi

    if [ "$free_space_gb" -lt "$MIN_FREE_SPACE_GB" ]; then
        log_error "Free space is ${free_space_gb}GB (minimum required: ${MIN_FREE_SPACE_GB}GB)"
        exit 1
    fi

    log_info "Disk check passed: ${free_space_gb}GB free, ${disk_usage}% used"
}

check_mysql_connection() {
    log_info "Checking MySQL connectivity to ${MYSQL_HOST}:${MYSQL_PORT}"

    if ! ${DOCKER_CMD} exec ${MYSQL_HOST} mysqladmin ping -h localhost -u root -p"${MYSQL_ROOT_PASSWORD}" &> /dev/null; then
        log_error "Cannot connect to MySQL server"
        exit 1
    fi

    log_info "MySQL connection successful"
}

check_compression_tool() {
    if [ "${COMPRESSION_TOOL}" = "auto" ]; then
        if command -v pigz &> /dev/null; then
            COMPRESSION_TOOL="pigz"
            log_info "Using pigz for parallel compression"
        else
            COMPRESSION_TOOL="gzip"
            log_info "Using gzip for compression (install pigz for faster compression)"
        fi
    fi

    if ! command -v ${COMPRESSION_TOOL} &> /dev/null; then
        log_error "Compression tool ${COMPRESSION_TOOL} not found"
        exit 1
    fi
}

# ============================================
# Backup Type Determination
# ============================================

determine_backup_type() {
    local day_of_week=$(date +%w)
    local day_of_month=$(date +%d)

    # Remove leading zero from day
    day_of_month=$((10#$day_of_month))

    if [ "$day_of_month" -eq "$MONTHLY_DAY" ]; then
        BACKUP_TYPE="${BACKUP_TYPE_MONTHLY}"
        BACKUP_DEST="${MONTHLY_DIR}"
    elif [ "$day_of_week" -eq "$WEEKLY_DAY" ]; then
        BACKUP_TYPE="${BACKUP_TYPE_WEEKLY}"
        BACKUP_DEST="${WEEKLY_DIR}"
    else
        BACKUP_TYPE="${BACKUP_TYPE_DAILY}"
        BACKUP_DEST="${DAILY_DIR}"
    fi

    log_info "Backup type determined: ${BACKUP_TYPE}"
    mkdir -p "${BACKUP_DEST}"
}

# ============================================
# XtraBackup Functions
# ============================================

perform_backup() {
    log_info "Starting XtraBackup hot backup (zero downtime)"

    # Create temporary directory for backup
    mkdir -p "${TEMP_DIR}"
    local temp_backup_dir="${TEMP_DIR}/${BACKUP_NAME}"

    # Determine number of parallel threads
    local threads="${PARALLEL_THREADS}"
    if [ "${threads}" = "auto" ]; then
        threads=$(nproc)
    fi

    log_info "Using ${threads} parallel threads"

    # Determine MySQL connection method
    # Try to get MySQL port exposed to host
    local mysql_port=$(${DOCKER_CMD} port ${MYSQL_HOST} 3306 2>/dev/null | cut -d':' -f2 | head -n1)
    local mysql_host="127.0.0.1"

    if [ -z "$mysql_port" ]; then
        # Port not exposed, try to get container IP
        mysql_host=$(${DOCKER_CMD} inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ${MYSQL_HOST} 2>/dev/null | head -n1)
        mysql_port="3306"

        if [ -z "$mysql_host" ]; then
            log_error "Cannot determine MySQL connection method. Ensure MySQL container is running and accessible."
            EXIT_CODE=1
            return 1
        fi

        log_info "Connecting to MySQL via container IP: ${mysql_host}:${mysql_port}"
    else
        log_info "Connecting to MySQL via exposed port: ${mysql_host}:${mysql_port}"
    fi

    # Verify MySQL data directory exists
    if [ ! -d "${MYSQL_DATA_DIR}" ]; then
        log_error "MySQL data directory not found: ${MYSQL_DATA_DIR}"
        log_error "Please set MYSQL_DATA_DIR in config/.env to the host path of MySQL data"
        log_error "For Octeth: /opt/oempro/_dockerfiles/mysql/data_v8"
        EXIT_CODE=1
        return 1
    fi

    log_info "MySQL data directory: ${MYSQL_DATA_DIR}"

    # Run XtraBackup from HOST (not inside container)
    log_info "Running: xtrabackup --backup"

    if ${XTRABACKUP_BIN} --backup \
        --target-dir="${temp_backup_dir}" \
        --datadir="${MYSQL_DATA_DIR}" \
        --host="${mysql_host}" \
        --port="${mysql_port}" \
        --user=root \
        --password="${MYSQL_ROOT_PASSWORD}" \
        --parallel=${threads} \
        ${XTRABACKUP_EXTRA_OPTS} 2>&1 | tee -a "${LOG_FILE}"; then
        log_success "XtraBackup completed successfully"
    else
        log_error "XtraBackup failed"
        EXIT_CODE=1
        return 1
    fi

    # Prepare the backup (make it consistent)
    if [ "${VERIFY_BACKUP}" = "true" ]; then
        log_info "Preparing backup (applying transaction logs)"

        if ${XTRABACKUP_BIN} --prepare --target-dir="${temp_backup_dir}" 2>&1 | tee -a "${LOG_FILE}"; then
            log_success "Backup prepared successfully (ready for restore)"
        else
            log_error "Backup prepare failed"
            EXIT_CODE=1
            return 1
        fi
    fi

    echo "${temp_backup_dir}"
}

compress_backup() {
    local source_dir="$1"
    local dest_file="${BACKUP_DEST}/${BACKUP_NAME}.tar.gz"

    log_info "Compressing backup with ${COMPRESSION_TOOL}"

    local tar_cmd="tar cf - -C $(dirname ${source_dir}) $(basename ${source_dir})"
    local compress_cmd="${COMPRESSION_TOOL} -${COMPRESSION_LEVEL}"

    if ${tar_cmd} | ${compress_cmd} > "${dest_file}"; then
        log_success "Backup compressed: ${dest_file}"

        # Calculate size
        local size=$(du -h "${dest_file}" | cut -f1)
        log_info "Backup size: ${size}"

        # Create checksum
        local checksum=$(sha256sum "${dest_file}" | cut -d' ' -f1)
        echo "${checksum}  ${BACKUP_NAME}.tar.gz" > "${dest_file}.sha256"
        log_info "Checksum: ${checksum}"

        echo "${dest_file}"
    else
        log_error "Compression failed"
        EXIT_CODE=1
        return 1
    fi
}

# ============================================
# S3 Upload Functions
# ============================================

upload_to_s3() {
    if [ "${S3_UPLOAD_ENABLED}" != "true" ]; then
        log_info "S3 upload disabled, skipping"
        return 0
    fi

    local backup_file="$1"
    local checksum_file="${backup_file}.sha256"
    local s3_path="${BACKUP_TYPE}/$(basename ${backup_file})"

    log_info "Uploading to S3: s3://${S3_BUCKET}/${S3_PREFIX}/${s3_path}"

    if [ "${S3_UPLOAD_TOOL}" = "awscli" ]; then
        upload_with_aws_cli "$backup_file" "$s3_path"
    elif [ "${S3_UPLOAD_TOOL}" = "rclone" ]; then
        upload_with_rclone "$backup_file" "$s3_path"
    else
        log_error "Unknown S3 upload tool: ${S3_UPLOAD_TOOL}"
        return 1
    fi

    # Upload checksum file
    if [ -f "$checksum_file" ]; then
        if [ "${S3_UPLOAD_TOOL}" = "awscli" ]; then
            upload_with_aws_cli "$checksum_file" "${s3_path}.sha256"
        else
            upload_with_rclone "$checksum_file" "${s3_path}.sha256"
        fi
    fi
}

upload_with_aws_cli() {
    local file="$1"
    local s3_path="$2"

    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI not found"
        return 1
    fi

    # Set credentials if provided
    if [ -n "${AWS_ACCESS_KEY_ID:-}" ]; then
        export AWS_ACCESS_KEY_ID
        export AWS_SECRET_ACCESS_KEY
    fi

    if aws s3 cp "$file" "s3://${S3_BUCKET}/${S3_PREFIX}/${s3_path}" \
        --region "${S3_REGION}" \
        --storage-class "${S3_STORAGE_CLASS}" 2>&1 | tee -a "${LOG_FILE}"; then
        log_success "Uploaded to S3: ${s3_path}"
    else
        log_error "S3 upload failed"
        return 1
    fi
}

upload_with_rclone() {
    local file="$1"
    local s3_path="$2"

    if ! command -v rclone &> /dev/null; then
        log_error "rclone not found"
        return 1
    fi

    if rclone copy "$file" "${RCLONE_REMOTE}:${S3_BUCKET}/${S3_PREFIX}/${BACKUP_TYPE}/" 2>&1 | tee -a "${LOG_FILE}"; then
        log_success "Uploaded with rclone: ${s3_path}"
    else
        log_error "rclone upload failed"
        return 1
    fi
}

# ============================================
# Notification Functions
# ============================================

send_notifications() {
    local status="$1"
    local backup_file="${2:-}"

    if [ "$status" = "success" ]; then
        if [ "${NOTIFY_ON_FAILURE_ONLY}" = "true" ]; then
            log_info "Skipping success notification (NOTIFY_ON_FAILURE_ONLY=true)"
            return 0
        fi
        send_success_notification "$backup_file"
    else
        send_failure_notification
    fi
}

send_success_notification() {
    local backup_file="$1"
    local duration=$(($(date +%s) - BACKUP_START_TIME))
    local size=$(du -h "${backup_file}" 2>/dev/null | cut -f1 || echo "unknown")

    local message="Octeth MySQL backup completed successfully

Backup Details:
- Name: ${BACKUP_NAME}
- Type: ${BACKUP_TYPE}
- Size: ${size}
- Duration: ${duration}s
- Location: ${backup_file}
- S3: ${S3_UPLOAD_ENABLED}
"

    if [ "${EMAIL_NOTIFICATIONS}" = "true" ]; then
        send_email "${EMAIL_SUBJECT_SUCCESS}" "$message"
    fi

    if [ "${WEBHOOK_ENABLED}" = "true" ]; then
        local payload="${WEBHOOK_PAYLOAD_SUCCESS}"
        payload="${payload//%TIMESTAMP%/$(date -Iseconds)}"
        payload="${payload//%SIZE%/${size}}"
        send_webhook "$payload"
    fi
}

send_failure_notification() {
    local duration=$(($(date +%s) - BACKUP_START_TIME))

    local message="Octeth MySQL backup FAILED

Error Details:
- Name: ${BACKUP_NAME}
- Type: ${BACKUP_TYPE}
- Duration: ${duration}s
- Errors: ${ERROR_LOG}

Please check the log file: ${LOG_FILE}
"

    if [ "${EMAIL_NOTIFICATIONS}" = "true" ]; then
        send_email "${EMAIL_SUBJECT_FAILURE}" "$message"
    fi

    if [ "${WEBHOOK_ENABLED}" = "true" ]; then
        local payload="${WEBHOOK_PAYLOAD_FAILURE}"
        payload="${payload//%TIMESTAMP%/$(date -Iseconds)}"
        payload="${payload//%ERROR%/${ERROR_LOG}}"
        send_webhook "$payload"
    fi
}

send_email() {
    local subject="$1"
    local body="$2"

    if ! command -v mailx &> /dev/null && ! command -v sendmail &> /dev/null; then
        log_warn "No mail command found, skipping email notification"
        return 1
    fi

    echo "$body" | mail -s "$subject" "${EMAIL_TO}" 2>&1 | tee -a "${LOG_FILE}" || true
}

send_webhook() {
    local payload="$1"

    if ! command -v curl &> /dev/null; then
        log_warn "curl not found, skipping webhook notification"
        return 1
    fi

    curl -X POST "${WEBHOOK_URL}" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>&1 | tee -a "${LOG_FILE}" || true
}

# ============================================
# Main Function
# ============================================

main() {
    log_info "=========================================="
    log_info "Octeth MySQL Backup Started"
    log_info "=========================================="

    # Pre-flight checks
    check_lock_file
    check_xtrabackup
    check_compression_tool
    check_disk_space
    check_mysql_connection

    # Determine backup type
    determine_backup_type

    # Perform backup
    local temp_backup_dir
    if ! temp_backup_dir=$(perform_backup); then
        send_notifications "failure"
        exit 1
    fi

    # Compress backup
    local backup_file
    if ! backup_file=$(compress_backup "$temp_backup_dir"); then
        send_notifications "failure"
        exit 1
    fi

    # Upload to S3
    upload_to_s3 "$backup_file" || log_warn "S3 upload failed (continuing anyway)"

    # Success
    local duration=$(($(date +%s) - BACKUP_START_TIME))
    log_success "=========================================="
    log_success "Backup completed in ${duration}s"
    log_success "File: ${backup_file}"
    log_success "=========================================="

    send_notifications "success" "$backup_file"

    exit 0
}

# Run main function
main "$@"
