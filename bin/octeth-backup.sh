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
    echo "[${timestamp}] [${level}] ${message}" | tee -a "${LOG_FILE}" >&2
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
    # Streaming backups compress on the fly, so only the final compressed
    # artifact lands on disk in BACKUP_DIR (and, with KEEP_LOCAL_BACKUP=false,
    # only transiently until it is uploaded). No uncompressed staging copy is
    # written anymore, so we only validate the backup destination.
    mkdir -p "${BACKUP_DIR}"

    local disk_usage=$(df -h "${BACKUP_DIR}" | awk 'NR==2 {print $5}' | sed 's/%//')
    local free_space_gb=$(df -BG "${BACKUP_DIR}" | awk 'NR==2 {print $4}' | sed 's/G//')

    if [ "$disk_usage" -gt "$MAX_DISK_USAGE" ]; then
        log_error "Backup directory disk usage is ${disk_usage}% (threshold: ${MAX_DISK_USAGE}%)"
        exit 1
    fi

    if [ "$free_space_gb" -lt "$MIN_FREE_SPACE_GB" ]; then
        log_error "Backup directory free space is ${free_space_gb}GB (minimum required: ${MIN_FREE_SPACE_GB}GB)"
        exit 1
    fi

    # Rough sanity check: a compressed xbstream is typically ~40% of the data
    # directory size. Abort early if the destination clearly cannot hold it.
    if [ -d "${MYSQL_DATA_DIR}" ]; then
        local db_size_gb=$(du -sb "${MYSQL_DATA_DIR}" 2>/dev/null | awk '{print int($1/1024/1024/1024)}')
        local est_compressed=$((db_size_gb * 2 / 5 + 1))  # ~40% of DB + 1GB buffer

        log_info "Database size: ~${db_size_gb}GB, estimated compressed backup: ~${est_compressed}GB, ${free_space_gb}GB free"

        if [ "$free_space_gb" -lt "$est_compressed" ]; then
            log_error "Insufficient space for compressed backup in ${BACKUP_DIR}"
            log_error "Estimated required: ~${est_compressed}GB, Available: ${free_space_gb}GB"
            exit 1
        fi
    fi

    log_info "Backup directory disk check passed: ${free_space_gb}GB free, ${disk_usage}% used"
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
    log_info "Starting XtraBackup streaming hot backup (zero downtime)"

    # Final compressed artifact. We stream xbstream straight into the compressor,
    # so the backup is written to disk exactly once, already compressed. There is
    # no uncompressed staging copy and no separate tar/compress pass.
    local dest_file="${BACKUP_DEST}/${BACKUP_NAME}.xbstream.gz"

    # Determine number of parallel threads
    local threads="${PARALLEL_THREADS}"
    if [ "${threads}" = "auto" ]; then
        threads=$(nproc)
    fi

    log_info "Using ${threads} parallel threads"

    # Determine MySQL connection method
    local mysql_port=$(${DOCKER_CMD} port ${MYSQL_HOST} 3306 2>/dev/null | cut -d':' -f2 | head -n1)
    local mysql_host="127.0.0.1"

    if [ -z "$mysql_port" ]; then
        # Port not exposed, check if container uses host network
        local network_mode=$(${DOCKER_CMD} inspect -f '{{.HostConfig.NetworkMode}}' ${MYSQL_HOST} 2>/dev/null)

        if [ "$network_mode" = "host" ]; then
            # Host network mode - MySQL is directly on the host
            mysql_host="127.0.0.1"
            mysql_port="3306"
            log_info "Connecting to MySQL via host network: ${mysql_host}:${mysql_port}"
        else
            # Bridge/custom network - get container IP
            mysql_host=$(${DOCKER_CMD} inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ${MYSQL_HOST} 2>/dev/null | head -n1)
            mysql_port="3306"

            if [ -z "$mysql_host" ]; then
                log_error "Cannot determine MySQL connection method. Ensure MySQL container is running and accessible."
                EXIT_CODE=1
                return 1
            fi

            log_info "Connecting to MySQL via container IP: ${mysql_host}:${mysql_port}"
        fi
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

    # Binary logs often live outside the data directory (e.g. a sibling log_v8/).
    # When MYSQL_LOG_BIN is set, XtraBackup is told the binlog basename so it can
    # capture the binlog and its coordinates; without it the backup can fail.
    #
    # The binlog *index* file is read from a SEPARATE path (the server's
    # log_bin_index variable), which a containerized MySQL reports as its
    # in-container path (e.g. /var/log/mysql/mysql-bin.index) — a path that does
    # not exist on the host where xtrabackup runs. We therefore also pass
    # --log-bin-index. By convention the index sits next to the binlogs as
    # <basename>.index, so we derive it from MYSQL_LOG_BIN unless MYSQL_LOG_BIN_INDEX
    # is set explicitly. Leave MYSQL_LOG_BIN empty if binary logging is disabled.
    local log_bin_opt=""
    local log_bin_index_opt=""
    if [ -n "${MYSQL_LOG_BIN:-}" ]; then
        log_bin_opt="--log-bin=${MYSQL_LOG_BIN}"
        local log_bin_index="${MYSQL_LOG_BIN_INDEX:-${MYSQL_LOG_BIN}.index}"
        log_bin_index_opt="--log-bin-index=${log_bin_index}"
        log_info "Including binary logs: ${MYSQL_LOG_BIN} (index: ${log_bin_index})"
    fi

    # Run XtraBackup from HOST (not inside container) and stream the xbstream
    # output directly into the compressor. pipefail (set -o pipefail) makes the
    # whole pipeline fail if either xtrabackup or the compressor fails.
    log_info "Streaming backup to: ${dest_file} (compressed with ${COMPRESSION_TOOL})"

    if ionice -c 3 nice -n 19 ${XTRABACKUP_BIN} --backup \
        --datadir="${MYSQL_DATA_DIR}" \
        --host="${mysql_host}" \
        --port="${mysql_port}" \
        --user=root \
        --password="${MYSQL_ROOT_PASSWORD}" \
        --parallel=${threads} \
        ${log_bin_opt} \
        ${log_bin_index_opt} \
        --stream=xbstream \
        ${XTRABACKUP_EXTRA_OPTS:-} 2>> "${LOG_FILE}" \
        | ${COMPRESSION_TOOL} -${COMPRESSION_LEVEL} > "${dest_file}"; then
        log_success "XtraBackup stream completed"
    else
        log_error "XtraBackup streaming backup failed"
        rm -f "${dest_file}"
        EXIT_CODE=1
        return 1
    fi

    # A streamed backup cannot be prepared in place; the prepare step now happens
    # at restore time (octeth-restore.sh). Here we instead validate that the
    # compressed archive is intact (not truncated/corrupt), which is cheap.
    if [ "${VERIFY_BACKUP}" = "true" ]; then
        log_info "Verifying compressed backup integrity"

        if ${COMPRESSION_TOOL} -t "${dest_file}" 2>> "${LOG_FILE}"; then
            log_success "Backup integrity check passed"
        else
            log_error "Backup integrity check failed (corrupt or truncated archive)"
            rm -f "${dest_file}"
            EXIT_CODE=1
            return 1
        fi
    fi

    # Size + checksum
    local size=$(du -h "${dest_file}" | cut -f1)
    log_info "Backup size: ${size}"

    local checksum=$(sha256sum "${dest_file}" | cut -d' ' -f1)
    echo "${checksum}  ${BACKUP_NAME}.xbstream.gz" > "${dest_file}.sha256"
    log_info "Checksum: ${checksum}"

    echo "${dest_file}"
}

# ============================================
# Cloud Storage Upload Functions
# ============================================

upload_to_cloud() {
    local backup_file="$1"

    if [ "${CLOUD_STORAGE_PROVIDER}" = "s3" ]; then
        upload_to_s3 "$backup_file"
    elif [ "${CLOUD_STORAGE_PROVIDER}" = "gcs" ]; then
        upload_to_gcs "$backup_file"
    elif [ "${CLOUD_STORAGE_PROVIDER}" = "r2" ]; then
        upload_to_r2 "$backup_file"
    elif [ "${CLOUD_STORAGE_PROVIDER}" = "none" ]; then
        log_info "Cloud storage disabled, skipping upload"
        return 0
    else
        log_error "Unknown cloud storage provider: ${CLOUD_STORAGE_PROVIDER}"
        return 1
    fi
}

# ============================================
# S3 Upload Functions
# ============================================

upload_to_s3() {
    local backup_file="$1"
    local checksum_file="${backup_file}.sha256"
    local s3_path="${BACKUP_TYPE}/$(basename ${backup_file})"

    log_info "Uploading to S3: s3://${S3_BUCKET}/${S3_PREFIX}/${s3_path}"

    # The data upload MUST succeed; if it fails, return failure now so the caller
    # never deletes the local copy (KEEP_LOCAL_BACKUP). Checksum upload is best-effort.
    if [ "${S3_UPLOAD_TOOL}" = "awscli" ]; then
        upload_s3_with_aws_cli "$backup_file" "$s3_path" || return 1
    elif [ "${S3_UPLOAD_TOOL}" = "rclone" ]; then
        upload_s3_with_rclone "$backup_file" "$s3_path" || return 1
    else
        log_error "Unknown S3 upload tool: ${S3_UPLOAD_TOOL}"
        return 1
    fi

    # Upload checksum file (best-effort)
    if [ -f "$checksum_file" ]; then
        if [ "${S3_UPLOAD_TOOL}" = "awscli" ]; then
            upload_s3_with_aws_cli "$checksum_file" "${s3_path}.sha256" || log_warn "Checksum upload failed"
        else
            upload_s3_with_rclone "$checksum_file" "${s3_path}.sha256" || log_warn "Checksum upload failed"
        fi
    fi

    return 0
}

upload_s3_with_aws_cli() {
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

upload_s3_with_rclone() {
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
# GCS Upload Functions
# ============================================

upload_to_gcs() {
    local backup_file="$1"
    local checksum_file="${backup_file}.sha256"
    local gcs_path="${BACKUP_TYPE}/$(basename ${backup_file})"

    log_info "Uploading to GCS: gs://${GCS_BUCKET}/${GCS_PREFIX}/${gcs_path}"

    # The data upload MUST succeed; if it fails, return failure now so the caller
    # never deletes the local copy (KEEP_LOCAL_BACKUP). Checksum upload is best-effort.
    if [ "${GCS_UPLOAD_TOOL}" = "gsutil" ]; then
        upload_gcs_with_gsutil "$backup_file" "$gcs_path" || return 1
    elif [ "${GCS_UPLOAD_TOOL}" = "rclone" ]; then
        upload_gcs_with_rclone "$backup_file" "$gcs_path" || return 1
    else
        log_error "Unknown GCS upload tool: ${GCS_UPLOAD_TOOL}"
        return 1
    fi

    # Upload checksum file (best-effort)
    if [ -f "$checksum_file" ]; then
        if [ "${GCS_UPLOAD_TOOL}" = "gsutil" ]; then
            upload_gcs_with_gsutil "$checksum_file" "${gcs_path}.sha256" || log_warn "Checksum upload failed"
        else
            upload_gcs_with_rclone "$checksum_file" "${gcs_path}.sha256" || log_warn "Checksum upload failed"
        fi
    fi

    return 0
}

upload_gcs_with_gsutil() {
    local file="$1"
    local gcs_path="$2"

    if ! command -v gsutil &> /dev/null; then
        log_error "gsutil not found. Install Google Cloud SDK: https://cloud.google.com/sdk/docs/install"
        return 1
    fi

    # Set credentials if provided
    if [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then
        export GOOGLE_APPLICATION_CREDENTIALS="${GOOGLE_APPLICATION_CREDENTIALS}"

        # Activate service account with gcloud (gsutil often ignores GOOGLE_APPLICATION_CREDENTIALS)
        if [ -f "${GOOGLE_APPLICATION_CREDENTIALS}" ] && command -v gcloud &> /dev/null; then
            gcloud auth activate-service-account --key-file="${GOOGLE_APPLICATION_CREDENTIALS}" &>/dev/null || true
        fi
    fi

    # Set project ID via environment variable if provided
    if [ -n "${GCS_PROJECT_ID:-}" ]; then
        export CLOUDSDK_CORE_PROJECT="${GCS_PROJECT_ID}"
    fi

    if gsutil -h "Content-Type:application/gzip" \
        cp -v "$file" "gs://${GCS_BUCKET}/${GCS_PREFIX}/${gcs_path}" 2>&1 | tee -a "${LOG_FILE}"; then

        # Set storage class if specified
        if [ -n "${GCS_STORAGE_CLASS:-}" ] && [ "${GCS_STORAGE_CLASS}" != "STANDARD" ]; then
            gsutil rewrite -s "${GCS_STORAGE_CLASS}" \
                "gs://${GCS_BUCKET}/${GCS_PREFIX}/${gcs_path}" 2>&1 | tee -a "${LOG_FILE}" || true
        fi

        log_success "Uploaded to GCS: ${gcs_path}"
    else
        log_error "GCS upload failed"
        return 1
    fi
}

upload_gcs_with_rclone() {
    local file="$1"
    local gcs_path="$2"

    if ! command -v rclone &> /dev/null; then
        log_error "rclone not found"
        return 1
    fi

    if rclone copy "$file" "${GCS_RCLONE_REMOTE}:${GCS_BUCKET}/${GCS_PREFIX}/${BACKUP_TYPE}/" 2>&1 | tee -a "${LOG_FILE}"; then
        log_success "Uploaded to GCS with rclone: ${gcs_path}"
    else
        log_error "rclone upload to GCS failed"
        return 1
    fi
}

# ============================================
# Cloudflare R2 Upload Functions
# ============================================

upload_to_r2() {
    local backup_file="$1"
    local checksum_file="${backup_file}.sha256"
    local r2_path="${BACKUP_TYPE}/$(basename ${backup_file})"

    log_info "Uploading to R2: https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com/${R2_BUCKET}/${R2_PREFIX}/${r2_path}"

    # The data upload MUST succeed; if it fails, return failure now so the caller
    # never deletes the local copy (KEEP_LOCAL_BACKUP). Checksum upload is best-effort.
    if [ "${R2_UPLOAD_TOOL}" = "awscli" ]; then
        upload_r2_with_aws_cli "$backup_file" "$r2_path" || return 1
    elif [ "${R2_UPLOAD_TOOL}" = "rclone" ]; then
        upload_r2_with_rclone "$backup_file" "$r2_path" || return 1
    else
        log_error "Unknown R2 upload tool: ${R2_UPLOAD_TOOL}"
        return 1
    fi

    # Upload checksum file (best-effort)
    if [ -f "$checksum_file" ]; then
        if [ "${R2_UPLOAD_TOOL}" = "awscli" ]; then
            upload_r2_with_aws_cli "$checksum_file" "${r2_path}.sha256" || log_warn "Checksum upload failed"
        else
            upload_r2_with_rclone "$checksum_file" "${r2_path}.sha256" || log_warn "Checksum upload failed"
        fi
    fi

    return 0
}

upload_r2_with_aws_cli() {
    local file="$1"
    local r2_path="$2"

    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI not found"
        return 1
    fi

    # Set R2 credentials
    if [ -n "${R2_ACCESS_KEY_ID:-}" ]; then
        export AWS_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID}"
        export AWS_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY}"
    fi

    # R2 endpoint URL
    local r2_endpoint="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"

    if aws s3 cp "$file" "s3://${R2_BUCKET}/${R2_PREFIX}/${r2_path}" \
        --endpoint-url "${r2_endpoint}" 2>&1 | tee -a "${LOG_FILE}"; then
        log_success "Uploaded to R2: ${r2_path}"
    else
        log_error "R2 upload failed"
        return 1
    fi
}

upload_r2_with_rclone() {
    local file="$1"
    local r2_path="$2"

    if ! command -v rclone &> /dev/null; then
        log_error "rclone not found"
        return 1
    fi

    if rclone copy "$file" "${R2_RCLONE_REMOTE}:${R2_BUCKET}/${R2_PREFIX}/${BACKUP_TYPE}/" 2>&1 | tee -a "${LOG_FILE}"; then
        log_success "Uploaded to R2 with rclone: ${r2_path}"
    else
        log_error "rclone upload to R2 failed"
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
- Cloud Storage: ${CLOUD_STORAGE_PROVIDER}
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
    ulimit -n 65536

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

    # Perform streaming backup (xbstream -> compressor -> single compressed file)
    local backup_file
    if ! backup_file=$(perform_backup); then
        send_notifications "failure"
        exit 1
    fi

    # Upload to cloud storage
    local upload_ok=true
    if ! upload_to_cloud "$backup_file"; then
        upload_ok=false
        log_warn "Cloud upload failed (local copy retained for retry)"
    fi

    # Success banner + notification (while the file still exists, so size is known)
    local duration=$(($(date +%s) - BACKUP_START_TIME))
    log_success "=========================================="
    log_success "Backup completed in ${duration}s"
    log_success "File: ${backup_file}"
    log_success "=========================================="

    send_notifications "success" "$backup_file"

    # Remove the local copy when we don't keep local backups. Only delete once the
    # backup is safely in the cloud — never delete the last remaining copy.
    local keep_local="${KEEP_LOCAL_BACKUP:-true}"
    if [ "${keep_local}" = "false" ]; then
        if [ "${CLOUD_STORAGE_PROVIDER}" = "none" ]; then
            log_warn "KEEP_LOCAL_BACKUP=false but CLOUD_STORAGE_PROVIDER=none; keeping local backup (nowhere else to store it)"
        elif [ "${upload_ok}" = true ]; then
            log_info "Removing local backup (KEEP_LOCAL_BACKUP=false); retained in ${CLOUD_STORAGE_PROVIDER}"
            rm -f "${backup_file}" "${backup_file}.sha256"
        else
            log_warn "Keeping local backup because the cloud upload failed"
        fi
    fi

    exit 0
}

# Run main function
main "$@"
