#!/bin/bash
#
# Octeth ClickHouse Backup Tool
# Using clickhouse-backup for hot, zero-downtime backups
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
BACKUP_NAME="${CH_BACKUP_PREFIX}-${BACKUP_TIMESTAMP}"
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
    echo "[${timestamp}] [${level}] ${message}" | tee -a "${CH_LOG_FILE}" >&2
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

    if [ -f "${CH_LOCK_FILE}" ]; then
        log_info "Removing lock file"
        rm -f "${CH_LOCK_FILE}"
    fi

    if [ -d "${CH_TEMP_DIR}" ]; then
        log_info "Cleaning up temporary directory"
        rm -rf "${CH_TEMP_DIR}"
    fi

    return $exit_code
}

trap cleanup EXIT INT TERM

# ============================================
# Pre-flight Checks
# ============================================

check_lock_file() {
    if [ -f "${CH_LOCK_FILE}" ]; then
        local lock_pid=$(cat "${CH_LOCK_FILE}" 2>/dev/null || echo "")

        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
            log_error "Another ClickHouse backup is already running (PID: $lock_pid)"
            exit 1
        else
            log_warn "Stale lock file found, removing it"
            rm -f "${CH_LOCK_FILE}"
        fi
    fi

    echo $$ > "${CH_LOCK_FILE}"
    log_info "Lock file created: ${CH_LOCK_FILE}"
}

# ============================================
# clickhouse-backup Execution Helper
# ============================================

# Detect Docker network of the ClickHouse container
detect_ch_network() {
    if [ -n "${CH_DOCKER_NETWORK:-}" ]; then
        echo "${CH_DOCKER_NETWORK}"
        return 0
    fi

    local network=$(${DOCKER_CMD} inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' ${CH_HOST} 2>/dev/null | head -n1)
    if [ -n "$network" ]; then
        echo "$network"
        return 0
    fi

    log_error "Cannot detect Docker network for ${CH_HOST}. Set CH_DOCKER_NETWORK in .env"
    return 1
}

# Resolve the ClickHouse host to an IP address reachable from the sidecar container.
# On the default "bridge" network, container name DNS does not work, so we must
# resolve to the container's IP address. On user-defined networks, names work fine
# but using the IP is safe in both cases.
resolve_ch_host() {
    local network="$1"
    local ch_ip

    ch_ip=$(${DOCKER_CMD} inspect -f "{{(index .NetworkSettings.Networks \"${network}\").IPAddress}}" ${CH_HOST} 2>/dev/null)

    if [ -n "$ch_ip" ]; then
        echo "$ch_ip"
    else
        # Fallback to container name (works on user-defined networks)
        echo "${CH_HOST}"
    fi
}

# Run a clickhouse-backup command using either sidecar or internal mode
run_clickhouse_backup() {
    local ch_backup_mode="${CH_BACKUP_MODE:-sidecar}"

    if [ "$ch_backup_mode" = "sidecar" ]; then
        # Validate CH_DATA_DIR is set for sidecar mode
        if [ -z "${CH_DATA_DIR:-}" ] || [ ! -d "${CH_DATA_DIR}" ]; then
            log_error "CH_DATA_DIR is required for sidecar mode (current value: '${CH_DATA_DIR:-}')"
            log_error "Set CH_DATA_DIR to the host path mounted as /var/lib/clickhouse in the ClickHouse container"
            return 1
        fi

        local network
        network=$(detect_ch_network) || return 1

        local ch_connect_host
        ch_connect_host=$(resolve_ch_host "$network")

        ${DOCKER_CMD} run --rm \
            --network "$network" \
            --entrypoint clickhouse-backup \
            -v "${CH_DATA_DIR}:/var/lib/clickhouse" \
            -e CLICKHOUSE_HOST="${ch_connect_host}" \
            -e CLICKHOUSE_PORT="${CH_NATIVE_PORT:-9000}" \
            -e CLICKHOUSE_USERNAME="${CH_USER}" \
            -e CLICKHOUSE_PASSWORD="${CH_PASSWORD:-}" \
            "${CH_BACKUP_IMAGE:-altinity/clickhouse-backup:latest}" \
            "$@"
    elif [ "$ch_backup_mode" = "internal" ]; then
        ${DOCKER_CMD} exec ${CH_HOST} clickhouse-backup "$@"
    else
        log_error "Unknown CH_BACKUP_MODE: ${ch_backup_mode} (expected 'sidecar' or 'internal')"
        return 1
    fi
}

check_clickhouse_backup() {
    local ch_backup_mode="${CH_BACKUP_MODE:-sidecar}"

    if [ "$ch_backup_mode" = "sidecar" ]; then
        log_info "Backup mode: sidecar (using ${CH_BACKUP_IMAGE:-altinity/clickhouse-backup:latest})"

        # Validate CH_DATA_DIR
        if [ -z "${CH_DATA_DIR:-}" ] || [ ! -d "${CH_DATA_DIR}" ]; then
            log_error "CH_DATA_DIR is required for sidecar mode"
            log_error "Set CH_DATA_DIR to the host path mounted as /var/lib/clickhouse"
            log_error "Find it with: docker inspect ${CH_HOST} --format '{{range .Mounts}}{{if eq .Destination \"/var/lib/clickhouse\"}}{{.Source}}{{end}}{{end}}'"
            exit 1
        fi

        # Pull image if needed (check if it exists locally)
        if ! ${DOCKER_CMD} image inspect "${CH_BACKUP_IMAGE:-altinity/clickhouse-backup:latest}" &> /dev/null; then
            log_info "Pulling clickhouse-backup image..."
            if ! ${DOCKER_CMD} pull "${CH_BACKUP_IMAGE:-altinity/clickhouse-backup:latest}" >> "${CH_LOG_FILE}" 2>&1; then
                log_error "Failed to pull ${CH_BACKUP_IMAGE:-altinity/clickhouse-backup:latest}"
                exit 1
            fi
        fi

        local cb_version
        cb_version=$(run_clickhouse_backup --version 2>&1 | head -n1) || true
        log_info "Using clickhouse-backup (sidecar): ${cb_version}"

    elif [ "$ch_backup_mode" = "internal" ]; then
        log_info "Backup mode: internal (inside ${CH_HOST} container)"

        if ! ${DOCKER_CMD} exec ${CH_HOST} clickhouse-backup --version &> /dev/null; then
            log_error "clickhouse-backup not found inside container ${CH_HOST}"
            log_error "Either install it in the container or switch to sidecar mode:"
            log_error "  Set CH_BACKUP_MODE=sidecar in config/.env (recommended)"
            exit 1
        fi

        local cb_version=$(${DOCKER_CMD} exec ${CH_HOST} clickhouse-backup --version 2>&1 | head -n1)
        log_info "Using clickhouse-backup (internal): ${cb_version}"
    else
        log_error "Unknown CH_BACKUP_MODE: ${ch_backup_mode}"
        exit 1
    fi
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

check_disk_space() {
    # The compressed backup is written to CH_BACKUP_DIR. clickhouse-backup's local
    # "create" uses hardlinks to the data parts (near-zero extra space), and we tar
    # straight into the compressor, so we no longer stage a second uncompressed
    # copy. Validate the backup destination.
    mkdir -p "${CH_BACKUP_DIR}"

    local disk_usage=$(df -h "${CH_BACKUP_DIR}" | awk 'NR==2 {print $5}' | sed 's/%//')
    local free_space_gb=$(df -BG "${CH_BACKUP_DIR}" | awk 'NR==2 {print $4}' | sed 's/G//')

    if [ "$disk_usage" -gt "$MAX_DISK_USAGE" ]; then
        log_error "Backup directory disk usage is ${disk_usage}% (threshold: ${MAX_DISK_USAGE}%)"
        exit 1
    fi

    if [ "$free_space_gb" -lt "$MIN_FREE_SPACE_GB" ]; then
        log_error "Backup directory free space is ${free_space_gb}GB (minimum required: ${MIN_FREE_SPACE_GB}GB)"
        exit 1
    fi

    # Rough sanity check: estimate compressed size ~40% of the ClickHouse db size.
    local db_size_bytes=$(${DOCKER_CMD} exec ${CH_HOST} clickhouse-client \
        --user="${CH_USER}" ${CH_PASSWORD:+--password="${CH_PASSWORD}"} \
        --query="SELECT coalesce(sum(bytes_on_disk), 0) FROM system.parts WHERE active AND database='${CH_DATABASE}'" 2>/dev/null || echo "0")

    local db_size_gb=$((db_size_bytes / 1024 / 1024 / 1024))
    local est_compressed=$((db_size_gb * 2 / 5 + 1))  # ~40% of DB + 1GB buffer

    log_info "Database size: ~${db_size_gb}GB, estimated compressed backup: ~${est_compressed}GB, ${free_space_gb}GB free"

    if [ "$free_space_gb" -lt "$est_compressed" ]; then
        log_error "Insufficient space for compressed backup in ${CH_BACKUP_DIR}"
        log_error "Estimated required: ~${est_compressed}GB, Available: ${free_space_gb}GB"
        exit 1
    fi

    log_info "Backup directory disk check passed: ${free_space_gb}GB free, ${disk_usage}% used"
}

check_clickhouse_connection() {
    log_info "Checking ClickHouse connectivity to ${CH_HOST}"

    if ! ${DOCKER_CMD} exec ${CH_HOST} clickhouse-client \
        --user="${CH_USER}" ${CH_PASSWORD:+--password="${CH_PASSWORD}"} \
        --query="SELECT 1" &> /dev/null; then
        log_error "Cannot connect to ClickHouse server"
        exit 1
    fi

    log_info "ClickHouse connection successful"
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
        BACKUP_DEST="${CH_MONTHLY_DIR}"
    elif [ "$day_of_week" -eq "$WEEKLY_DAY" ]; then
        BACKUP_TYPE="${BACKUP_TYPE_WEEKLY}"
        BACKUP_DEST="${CH_WEEKLY_DIR}"
    else
        BACKUP_TYPE="${BACKUP_TYPE_DAILY}"
        BACKUP_DEST="${CH_DAILY_DIR}"
    fi

    log_info "Backup type determined: ${BACKUP_TYPE}"
    mkdir -p "${BACKUP_DEST}"
}

# ============================================
# ClickHouse Backup Functions
# ============================================

perform_backup() {
    log_info "Starting ClickHouse hot backup (zero downtime)"

    local dest_file="${BACKUP_DEST}/${BACKUP_NAME}.tar.gz"

    # Run clickhouse-backup create
    log_info "Running: clickhouse-backup create ${BACKUP_NAME}"

    if run_clickhouse_backup create \
        --tables="${CH_DATABASE}.*" \
        "${BACKUP_NAME}" >> "${CH_LOG_FILE}" 2>&1; then
        log_success "clickhouse-backup create completed successfully"
    else
        log_error "clickhouse-backup create failed"
        EXIT_CODE=1
        return 1
    fi

    # Compress the freshly created backup directly into the destination, streaming
    # tar -> compressor. This avoids staging a second full copy in CH_TEMP_DIR.
    # pipefail makes the pipeline fail if either tar or the compressor fails.
    log_info "Compressing backup with ${COMPRESSION_TOOL}"

    if [ -n "${CH_DATA_DIR:-}" ] && [ -d "${CH_DATA_DIR}/backup/${BACKUP_NAME}" ]; then
        # Backup directory is reachable on the host via the mounted volume
        log_info "Archiving from data directory: ${CH_DATA_DIR}/backup/${BACKUP_NAME}"
        if ! tar -cf - -C "${CH_DATA_DIR}/backup" "${BACKUP_NAME}" \
            | ${COMPRESSION_TOOL} -${COMPRESSION_LEVEL} > "${dest_file}"; then
            log_error "Compression failed"
            rm -f "${dest_file}"
            EXIT_CODE=1
            return 1
        fi
    else
        # Internal mode without host volume access: stream tar out of the container
        log_info "Archiving from container via docker exec tar"
        if ! ${DOCKER_CMD} exec ${CH_HOST} tar -cf - -C /var/lib/clickhouse/backup "${BACKUP_NAME}" \
            | ${COMPRESSION_TOOL} -${COMPRESSION_LEVEL} > "${dest_file}"; then
            log_error "Compression failed"
            rm -f "${dest_file}"
            EXIT_CODE=1
            return 1
        fi
    fi

    log_success "Backup compressed: ${dest_file}"

    # Size + checksum
    local size=$(du -h "${dest_file}" | cut -f1)
    log_info "Backup size: ${size}"

    local checksum=$(sha256sum "${dest_file}" | cut -d' ' -f1)
    echo "${checksum}  ${BACKUP_NAME}.tar.gz" > "${dest_file}.sha256"
    log_info "Checksum: ${checksum}"

    # Clean up the raw backup from clickhouse-backup local storage
    run_clickhouse_backup delete local "${BACKUP_NAME}" >> "${CH_LOG_FILE}" 2>&1 || \
        log_warn "Failed to clean up raw backup (non-fatal)"

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
    local s3_path="${CH_CLOUD_SUBDIR}/${BACKUP_TYPE}/$(basename ${backup_file})"

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
        --storage-class "${S3_STORAGE_CLASS}" 2>&1 | tee -a "${CH_LOG_FILE}"; then
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

    if rclone copy "$file" "${RCLONE_REMOTE}:${S3_BUCKET}/${S3_PREFIX}/${CH_CLOUD_SUBDIR}/${BACKUP_TYPE}/" 2>&1 | tee -a "${CH_LOG_FILE}"; then
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
    local gcs_path="${CH_CLOUD_SUBDIR}/${BACKUP_TYPE}/$(basename ${backup_file})"

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

        if [ -f "${GOOGLE_APPLICATION_CREDENTIALS}" ] && command -v gcloud &> /dev/null; then
            gcloud auth activate-service-account --key-file="${GOOGLE_APPLICATION_CREDENTIALS}" &>/dev/null || true
        fi
    fi

    if [ -n "${GCS_PROJECT_ID:-}" ]; then
        export CLOUDSDK_CORE_PROJECT="${GCS_PROJECT_ID}"
    fi

    if gsutil -h "Content-Type:application/gzip" \
        cp -v "$file" "gs://${GCS_BUCKET}/${GCS_PREFIX}/${gcs_path}" 2>&1 | tee -a "${CH_LOG_FILE}"; then

        if [ -n "${GCS_STORAGE_CLASS:-}" ] && [ "${GCS_STORAGE_CLASS}" != "STANDARD" ]; then
            gsutil rewrite -s "${GCS_STORAGE_CLASS}" \
                "gs://${GCS_BUCKET}/${GCS_PREFIX}/${gcs_path}" 2>&1 | tee -a "${CH_LOG_FILE}" || true
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

    if rclone copy "$file" "${GCS_RCLONE_REMOTE}:${GCS_BUCKET}/${GCS_PREFIX}/${CH_CLOUD_SUBDIR}/${BACKUP_TYPE}/" 2>&1 | tee -a "${CH_LOG_FILE}"; then
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
    local r2_path="${CH_CLOUD_SUBDIR}/${BACKUP_TYPE}/$(basename ${backup_file})"

    log_info "Uploading to R2: ${R2_BUCKET}/${R2_PREFIX}/${r2_path}"

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

    if [ -n "${R2_ACCESS_KEY_ID:-}" ]; then
        export AWS_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID}"
        export AWS_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY}"
    fi

    local r2_endpoint="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"

    if aws s3 cp "$file" "s3://${R2_BUCKET}/${R2_PREFIX}/${r2_path}" \
        --endpoint-url "${r2_endpoint}" 2>&1 | tee -a "${CH_LOG_FILE}"; then
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

    if rclone copy "$file" "${R2_RCLONE_REMOTE}:${R2_BUCKET}/${R2_PREFIX}/${CH_CLOUD_SUBDIR}/${BACKUP_TYPE}/" 2>&1 | tee -a "${CH_LOG_FILE}"; then
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

    local message="Octeth ClickHouse backup completed successfully

Backup Details:
- Name: ${BACKUP_NAME}
- Type: ${BACKUP_TYPE}
- Size: ${size}
- Duration: ${duration}s
- Location: ${backup_file}
- Cloud Storage: ${CLOUD_STORAGE_PROVIDER}
"

    if [ "${EMAIL_NOTIFICATIONS}" = "true" ]; then
        send_email "[SUCCESS] Octeth ClickHouse Backup Completed" "$message"
    fi

    if [ "${WEBHOOK_ENABLED}" = "true" ]; then
        local payload='{"text":"✅ Octeth ClickHouse backup completed (%SIZE%) at %TIMESTAMP%","status":"success","backup_size":"%SIZE%","timestamp":"%TIMESTAMP%"}'
        payload="${payload//%TIMESTAMP%/$(date -Iseconds)}"
        payload="${payload//%SIZE%/${size}}"
        send_webhook "$payload"
    fi
}

send_failure_notification() {
    local duration=$(($(date +%s) - BACKUP_START_TIME))

    local message="Octeth ClickHouse backup FAILED

Error Details:
- Name: ${BACKUP_NAME}
- Type: ${BACKUP_TYPE}
- Duration: ${duration}s
- Errors: ${ERROR_LOG}

Please check the log file: ${CH_LOG_FILE}
"

    if [ "${EMAIL_NOTIFICATIONS}" = "true" ]; then
        send_email "[FAILURE] Octeth ClickHouse Backup Failed" "$message"
    fi

    if [ "${WEBHOOK_ENABLED}" = "true" ]; then
        local payload='{"text":"🚨 Octeth ClickHouse backup FAILED at %TIMESTAMP%: %ERROR%","status":"failure","error":"%ERROR%","timestamp":"%TIMESTAMP%"}'
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

    echo "$body" | mail -s "$subject" "${EMAIL_TO}" 2>&1 | tee -a "${CH_LOG_FILE}" || true
}

send_webhook() {
    local payload="$1"

    if ! command -v curl &> /dev/null; then
        log_warn "curl not found, skipping webhook notification"
        return 1
    fi

    curl -X POST "${WEBHOOK_URL}" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>&1 | tee -a "${CH_LOG_FILE}" || true
}

# ============================================
# Main Function
# ============================================

main() {
    log_info "=========================================="
    log_info "Octeth ClickHouse Backup Started"
    log_info "=========================================="

    # Pre-flight checks
    check_lock_file
    check_clickhouse_backup
    check_compression_tool
    check_disk_space
    check_clickhouse_connection

    # Determine backup type
    determine_backup_type

    # Perform backup (clickhouse-backup create -> tar|compressor -> .tar.gz)
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
    log_success "ClickHouse backup completed in ${duration}s"
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
