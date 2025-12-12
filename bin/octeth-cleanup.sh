#!/bin/bash
#
# Octeth Backup Cleanup Script
# Implements retention policy: Daily (7) + Weekly (4) + Monthly (6)
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
    exit 1
fi

source "$CONFIG_FILE"

# ============================================
# Global Variables
# ============================================

DRY_RUN=false
VERBOSE=false

# ============================================
# Helper Functions (macOS/POSIX compatibility)
# ============================================

# Convert string to uppercase (works on Bash 3.x)
to_upper() {
    echo "$1" | tr '[:lower:]' '[:upper:]'
}

# Capitalize first letter (works on Bash 3.x)
capitalize() {
    local str="$1"
    local first=$(echo "${str:0:1}" | tr '[:lower:]' '[:upper:]')
    local rest="${str:1}"
    echo "${first}${rest}"
}

# ============================================
# Logging Functions
# ============================================

log() {
    local level="$1"
    shift
    local message="$@"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${level}] ${message}"
}

log_info() {
    log "INFO" "$@"
}

log_warn() {
    log "WARN" "$@"
}

log_success() {
    log "SUCCESS" "$@"
}

verbose_log() {
    if [ "$VERBOSE" = true ]; then
        log "DEBUG" "$@"
    fi
}

# ============================================
# Cleanup Functions
# ============================================

cleanup_directory() {
    local dir="$1"
    local retention_count="$2"
    local backup_type="$3"

    if [ ! -d "$dir" ]; then
        verbose_log "Directory does not exist: $dir"
        return 0
    fi

    log_info "Cleaning up ${backup_type} backups in: $dir"
    log_info "Retention policy: Keep last ${retention_count} backups"

    # Find all backup files, sorted by modification time (newest first)
    # macOS compatible: use ls -t for sorting by modification time
    local backup_files=()
    while IFS= read -r -d '' file; do
        backup_files+=("$file")
    done < <(find "$dir" -maxdepth 1 -name "*.tar.gz" -type f -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | tr '\n' '\0')
    local total_backups=${#backup_files[@]}

    log_info "Found ${total_backups} ${backup_type} backup(s)"

    if [ "$total_backups" -le "$retention_count" ]; then
        log_info "No cleanup needed (${total_backups} <= ${retention_count})"
        return 0
    fi

    local to_delete=$((total_backups - retention_count))
    log_info "Will delete ${to_delete} old backup(s)"

    # Delete old backups (keep the newest retention_count backups)
    local deleted=0
    for ((i=retention_count; i<total_backups; i++)); do
        local backup_file="${backup_files[$i]}"
        local backup_checksum="${backup_file}.sha256"

        if [ "$DRY_RUN" = true ]; then
            log_info "[DRY RUN] Would delete: $(basename $backup_file)"
        else
            log_info "Deleting: $(basename $backup_file)"
            rm -f "$backup_file"
            [ -f "$backup_checksum" ] && rm -f "$backup_checksum"
            deleted=$((deleted + 1))
        fi
    done

    if [ "$DRY_RUN" = false ]; then
        log_success "Deleted ${deleted} old ${backup_type} backup(s)"
    fi
}

cleanup_cloud_backups() {
    if [ "${CLOUD_STORAGE_PROVIDER}" = "s3" ]; then
        cleanup_s3_backups
    elif [ "${CLOUD_STORAGE_PROVIDER}" = "gcs" ]; then
        cleanup_gcs_backups
    elif [ "${CLOUD_STORAGE_PROVIDER}" = "r2" ]; then
        cleanup_r2_backups
    elif [ "${CLOUD_STORAGE_PROVIDER}" = "none" ]; then
        verbose_log "Cloud storage disabled, skipping cloud cleanup"
        return 0
    else
        log_warn "Unknown cloud storage provider: ${CLOUD_STORAGE_PROVIDER}"
        return 1
    fi
}

cleanup_s3_backups() {
    log_info "Cleaning up S3 backups"

    if [ "${S3_UPLOAD_TOOL}" = "awscli" ]; then
        cleanup_s3_with_aws_cli
    elif [ "${S3_UPLOAD_TOOL}" = "rclone" ]; then
        cleanup_s3_with_rclone
    else
        log_warn "Unknown S3 upload tool: ${S3_UPLOAD_TOOL}"
        return 1
    fi
}

cleanup_s3_with_aws_cli() {
    if ! command -v aws &> /dev/null; then
        log_warn "AWS CLI not found, skipping S3 cleanup"
        return 1
    fi

    # Set credentials if provided
    if [ -n "${AWS_ACCESS_KEY_ID:-}" ]; then
        export AWS_ACCESS_KEY_ID
        export AWS_SECRET_ACCESS_KEY
    fi

    # Cleanup each backup type in S3
    for backup_type in daily weekly monthly; do
        local s3_prefix="${S3_PREFIX}/${backup_type}/"

        # Get retention count for this type
        local retention_count
        case "$backup_type" in
            daily)
                retention_count=${RETENTION_DAILY}
                ;;
            weekly)
                retention_count=${RETENTION_WEEKLY}
                ;;
            monthly)
                retention_count=${RETENTION_MONTHLY}
                ;;
        esac

        log_info "Cleaning up S3 ${backup_type} backups (keep last ${retention_count})"

        # List all backups in S3 for this type
        local s3_backups=($(aws s3 ls "s3://${S3_BUCKET}/${s3_prefix}" --region "${S3_REGION}" 2>/dev/null | \
            grep "\.tar\.gz$" | sort -r | awk '{print $4}'))

        local total=${#s3_backups[@]}
        verbose_log "Found ${total} ${backup_type} backups in S3"

        if [ "$total" -le "$retention_count" ]; then
            verbose_log "No S3 cleanup needed for ${backup_type}"
            continue
        fi

        # Delete old backups
        for ((i=retention_count; i<total; i++)); do
            local backup_file="${s3_backups[$i]}"
            local s3_path="s3://${S3_BUCKET}/${s3_prefix}${backup_file}"

            if [ "$DRY_RUN" = true ]; then
                log_info "[DRY RUN] Would delete from S3: ${backup_file}"
            else
                log_info "Deleting from S3: ${backup_file}"
                aws s3 rm "$s3_path" --region "${S3_REGION}" 2>&1 || log_warn "Failed to delete: ${backup_file}"
                # Also delete checksum file if exists
                aws s3 rm "${s3_path}.sha256" --region "${S3_REGION}" 2>&1 || true
            fi
        done
    done
}

cleanup_s3_with_rclone() {
    if ! command -v rclone &> /dev/null; then
        log_warn "rclone not found, skipping S3 cleanup"
        return 1
    fi

    # Cleanup each backup type in S3
    for backup_type in daily weekly monthly; do
        local remote_path="${RCLONE_REMOTE}:${S3_BUCKET}/${S3_PREFIX}/${backup_type}/"

        # Get retention count for this type
        local retention_count
        case "$backup_type" in
            daily)
                retention_count=${RETENTION_DAILY}
                ;;
            weekly)
                retention_count=${RETENTION_WEEKLY}
                ;;
            monthly)
                retention_count=${RETENTION_MONTHLY}
                ;;
        esac

        log_info "Cleaning up S3 ${backup_type} backups (keep last ${retention_count})"

        # List all backups
        local s3_backups=($(rclone lsf "$remote_path" 2>/dev/null | grep "\.tar\.gz$" | sort -r))

        local total=${#s3_backups[@]}
        verbose_log "Found ${total} ${backup_type} backups in S3"

        if [ "$total" -le "$retention_count" ]; then
            verbose_log "No S3 cleanup needed for ${backup_type}"
            continue
        fi

        # Delete old backups
        for ((i=retention_count; i<total; i++)); do
            local backup_file="${s3_backups[$i]}"

            if [ "$DRY_RUN" = true ]; then
                log_info "[DRY RUN] Would delete from S3: ${backup_file}"
            else
                log_info "Deleting from S3: ${backup_file}"
                rclone delete "${remote_path}${backup_file}" 2>&1 || log_warn "Failed to delete: ${backup_file}"
            fi
        done
    done
}

# ============================================
# GCS Cleanup Functions
# ============================================

cleanup_gcs_backups() {
    log_info "Cleaning up GCS backups"

    if [ "${GCS_UPLOAD_TOOL}" = "gsutil" ]; then
        cleanup_gcs_with_gsutil
    elif [ "${GCS_UPLOAD_TOOL}" = "rclone" ]; then
        cleanup_gcs_with_rclone
    else
        log_warn "Unknown GCS upload tool: ${GCS_UPLOAD_TOOL}"
        return 1
    fi
}

cleanup_gcs_with_gsutil() {
    if ! command -v gsutil &> /dev/null; then
        log_warn "gsutil not found, skipping GCS cleanup"
        return 1
    fi

    # Set credentials if provided
    if [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then
        export GOOGLE_APPLICATION_CREDENTIALS
    fi

    local gsutil_opts=""
    if [ -n "${GCS_PROJECT_ID:-}" ]; then
        gsutil_opts="-u ${GCS_PROJECT_ID}"
    fi

    # Cleanup each backup type in GCS
    for backup_type in daily weekly monthly; do
        local gcs_prefix="gs://${GCS_BUCKET}/${GCS_PREFIX}/${backup_type}/"

        # Get retention count for this type
        local retention_count
        case "$backup_type" in
            daily)
                retention_count=${RETENTION_DAILY}
                ;;
            weekly)
                retention_count=${RETENTION_WEEKLY}
                ;;
            monthly)
                retention_count=${RETENTION_MONTHLY}
                ;;
        esac

        log_info "Cleaning up GCS ${backup_type} backups (keep last ${retention_count})"

        # List all backups in GCS for this type
        local gcs_backups=($(gsutil ${gsutil_opts} ls "$gcs_prefix" 2>/dev/null | \
            grep "\.tar\.gz$" | sort -r | xargs -n1 basename))

        local total=${#gcs_backups[@]}
        verbose_log "Found ${total} ${backup_type} backups in GCS"

        if [ "$total" -le "$retention_count" ]; then
            verbose_log "No GCS cleanup needed for ${backup_type}"
            continue
        fi

        # Delete old backups
        for ((i=retention_count; i<total; i++)); do
            local backup_file="${gcs_backups[$i]}"
            local gcs_path="${gcs_prefix}${backup_file}"

            if [ "$DRY_RUN" = true ]; then
                log_info "[DRY RUN] Would delete from GCS: ${backup_file}"
            else
                log_info "Deleting from GCS: ${backup_file}"
                gsutil ${gsutil_opts} rm "$gcs_path" 2>&1 || log_warn "Failed to delete: ${backup_file}"
                # Also delete checksum file if exists
                gsutil ${gsutil_opts} rm "${gcs_path}.sha256" 2>&1 || true
            fi
        done
    done
}

cleanup_gcs_with_rclone() {
    if ! command -v rclone &> /dev/null; then
        log_warn "rclone not found, skipping GCS cleanup"
        return 1
    fi

    # Cleanup each backup type in GCS
    for backup_type in daily weekly monthly; do
        local remote_path="${GCS_RCLONE_REMOTE}:${GCS_BUCKET}/${GCS_PREFIX}/${backup_type}/"

        # Get retention count for this type
        local retention_count
        case "$backup_type" in
            daily)
                retention_count=${RETENTION_DAILY}
                ;;
            weekly)
                retention_count=${RETENTION_WEEKLY}
                ;;
            monthly)
                retention_count=${RETENTION_MONTHLY}
                ;;
        esac

        log_info "Cleaning up GCS ${backup_type} backups (keep last ${retention_count})"

        # List all backups
        local gcs_backups=($(rclone lsf "$remote_path" 2>/dev/null | grep "\.tar\.gz$" | sort -r))

        local total=${#gcs_backups[@]}
        verbose_log "Found ${total} ${backup_type} backups in GCS"

        if [ "$total" -le "$retention_count" ]; then
            verbose_log "No GCS cleanup needed for ${backup_type}"
            continue
        fi

        # Delete old backups
        for ((i=retention_count; i<total; i++)); do
            local backup_file="${gcs_backups[$i]}"

            if [ "$DRY_RUN" = true ]; then
                log_info "[DRY RUN] Would delete from GCS: ${backup_file}"
            else
                log_info "Deleting from GCS: ${backup_file}"
                rclone delete "${remote_path}${backup_file}" 2>&1 || log_warn "Failed to delete: ${backup_file}"
            fi
        done
    done
}

# ============================================
# Cloudflare R2 Cleanup Functions
# ============================================

cleanup_r2_backups() {
    log_info "Cleaning up R2 backups"

    if [ "${R2_UPLOAD_TOOL}" = "awscli" ]; then
        cleanup_r2_with_aws_cli
    elif [ "${R2_UPLOAD_TOOL}" = "rclone" ]; then
        cleanup_r2_with_rclone
    else
        log_warn "Unknown R2 upload tool: ${R2_UPLOAD_TOOL}"
        return 1
    fi
}

cleanup_r2_with_aws_cli() {
    if ! command -v aws &> /dev/null; then
        log_warn "AWS CLI not found, skipping R2 cleanup"
        return 1
    fi

    # Set R2 credentials
    if [ -n "${R2_ACCESS_KEY_ID:-}" ]; then
        export AWS_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID}"
        export AWS_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY}"
    fi

    # R2 endpoint URL
    local r2_endpoint="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"

    # Cleanup each backup type in R2
    for backup_type in daily weekly monthly; do
        local r2_prefix="${R2_PREFIX}/${backup_type}/"

        # Get retention count for this type
        local retention_count
        case "$backup_type" in
            daily)
                retention_count=${RETENTION_DAILY}
                ;;
            weekly)
                retention_count=${RETENTION_WEEKLY}
                ;;
            monthly)
                retention_count=${RETENTION_MONTHLY}
                ;;
        esac

        log_info "Cleaning up R2 ${backup_type} backups (keep last ${retention_count})"

        # List all backups in R2 for this type
        local r2_backups=($(aws s3 ls "s3://${R2_BUCKET}/${r2_prefix}" --endpoint-url "${r2_endpoint}" 2>/dev/null | \
            grep "\.tar\.gz$" | sort -r | awk '{print $4}'))

        local total=${#r2_backups[@]}
        verbose_log "Found ${total} ${backup_type} backups in R2"

        if [ "$total" -le "$retention_count" ]; then
            verbose_log "No R2 cleanup needed for ${backup_type}"
            continue
        fi

        # Delete old backups
        for ((i=retention_count; i<total; i++)); do
            local backup_file="${r2_backups[$i]}"
            local r2_path="s3://${R2_BUCKET}/${r2_prefix}${backup_file}"

            if [ "$DRY_RUN" = true ]; then
                log_info "[DRY RUN] Would delete from R2: ${backup_file}"
            else
                log_info "Deleting from R2: ${backup_file}"
                aws s3 rm "$r2_path" --endpoint-url "${r2_endpoint}" 2>&1 || log_warn "Failed to delete: ${backup_file}"
                # Also delete checksum file if exists
                aws s3 rm "${r2_path}.sha256" --endpoint-url "${r2_endpoint}" 2>&1 || true
            fi
        done
    done
}

cleanup_r2_with_rclone() {
    if ! command -v rclone &> /dev/null; then
        log_warn "rclone not found, skipping R2 cleanup"
        return 1
    fi

    # Cleanup each backup type in R2
    for backup_type in daily weekly monthly; do
        local remote_path="${R2_RCLONE_REMOTE}:${R2_BUCKET}/${R2_PREFIX}/${backup_type}/"

        # Get retention count for this type
        local retention_count
        case "$backup_type" in
            daily)
                retention_count=${RETENTION_DAILY}
                ;;
            weekly)
                retention_count=${RETENTION_WEEKLY}
                ;;
            monthly)
                retention_count=${RETENTION_MONTHLY}
                ;;
        esac

        log_info "Cleaning up R2 ${backup_type} backups (keep last ${retention_count})"

        # List all backups
        local r2_backups=($(rclone lsf "$remote_path" 2>/dev/null | grep "\.tar\.gz$" | sort -r))

        local total=${#r2_backups[@]}
        verbose_log "Found ${total} ${backup_type} backups in R2"

        if [ "$total" -le "$retention_count" ]; then
            verbose_log "No R2 cleanup needed for ${backup_type}"
            continue
        fi

        # Delete old backups
        for ((i=retention_count; i<total; i++)); do
            local backup_file="${r2_backups[$i]}"

            if [ "$DRY_RUN" = true ]; then
                log_info "[DRY RUN] Would delete from R2: ${backup_file}"
            else
                log_info "Deleting from R2: ${backup_file}"
                rclone delete "${remote_path}${backup_file}" 2>&1 || log_warn "Failed to delete: ${backup_file}"
            fi
        done
    done
}

cleanup_old_logs() {
    local log_dir=$(dirname "${LOG_FILE}")

    if [ ! -d "$log_dir" ]; then
        return 0
    fi

    log_info "Cleaning up old log files (older than ${LOG_RETENTION_DAYS} days)"

    local deleted=0
    while IFS= read -r -d '' logfile; do
        if [ "$DRY_RUN" = true ]; then
            log_info "[DRY RUN] Would delete log: $(basename $logfile)"
        else
            verbose_log "Deleting old log: $(basename $logfile)"
            rm -f "$logfile"
            deleted=$((deleted + 1))
        fi
    done < <(find "$log_dir" -name "*.log" -type f -mtime +${LOG_RETENTION_DAYS} -print0)

    if [ "$DRY_RUN" = false ] && [ "$deleted" -gt 0 ]; then
        log_success "Deleted ${deleted} old log file(s)"
    fi
}

# ============================================
# Statistics Functions
# ============================================

show_statistics() {
    log_info "=========================================="
    log_info "Backup Statistics"
    log_info "=========================================="

    # Count backups by type
    for backup_type in daily weekly monthly; do
        local dir_var="$(to_upper "$backup_type")_DIR"
        local dir="${!dir_var}"

        if [ -d "$dir" ]; then
            local count=$(find "$dir" -maxdepth 1 -name "*.tar.gz" -type f | wc -l)
            local total_size=$(du -sh "$dir" 2>/dev/null | cut -f1 || echo "0")
            log_info "$(capitalize "$backup_type") backups: ${count} (${total_size})"
        fi
    done

    # Total backup size
    if [ -d "${BACKUP_DIR}" ]; then
        local total_size=$(du -sh "${BACKUP_DIR}" 2>/dev/null | cut -f1 || echo "0")
        log_info "Total backup size: ${total_size}"
    fi

    log_info "=========================================="
}

# ============================================
# Usage Function
# ============================================

usage() {
    cat << EOF
Usage: $(basename $0) [OPTIONS]

Octeth Backup Cleanup Script
Implements retention policy: Daily (${RETENTION_DAILY}) + Weekly (${RETENTION_WEEKLY}) + Monthly (${RETENTION_MONTHLY})

OPTIONS:
    -d, --dry-run       Show what would be deleted without actually deleting
    -v, --verbose       Enable verbose output
    -s, --stats         Show backup statistics only (no cleanup)
    -h, --help          Display this help message

EXAMPLES:
    # Perform cleanup
    $(basename $0)

    # Dry run (see what would be deleted)
    $(basename $0) --dry-run

    # Show backup statistics
    $(basename $0) --stats

    # Verbose mode
    $(basename $0) --verbose

EOF
    exit 0
}

# ============================================
# Main Function
# ============================================

main() {
    local stats_only=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -d|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -s|--stats)
                stats_only=true
                shift
                ;;
            -h|--help)
                usage
                ;;
            *)
                echo "Unknown option: $1"
                usage
                ;;
        esac
    done

    log_info "=========================================="
    log_info "Octeth Backup Cleanup"
    log_info "=========================================="

    if [ "$DRY_RUN" = true ]; then
        log_info "DRY RUN MODE - No files will be deleted"
    fi

    if [ "$stats_only" = true ]; then
        show_statistics
        exit 0
    fi

    # Cleanup local backups
    cleanup_directory "${DAILY_DIR}" "${RETENTION_DAILY}" "daily"
    cleanup_directory "${WEEKLY_DIR}" "${RETENTION_WEEKLY}" "weekly"
    cleanup_directory "${MONTHLY_DIR}" "${RETENTION_MONTHLY}" "monthly"

    # Cleanup cloud backups (S3 or GCS)
    cleanup_cloud_backups

    # Cleanup old logs
    cleanup_old_logs

    # Show statistics
    show_statistics

    log_success "Cleanup completed"
}

# Run main function
main "$@"
