#!/bin/bash
#
# Octeth MySQL Restore Script
# Restores MySQL database from XtraBackup backups
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

RESTORE_SOURCE=""
RESTORE_FROM_S3=false
FORCE_RESTORE=false
SKIP_CONFIRMATION=false

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

# Get file modification date (works on macOS and Linux)
get_file_date() {
    local file="$1"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$file"
    else
        stat -c %y "$file" | cut -d' ' -f1,2 | cut -d'.' -f1
    fi
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

log_error() {
    log "ERROR" "$@"
}

log_warn() {
    log "WARN" "$@"
}

log_success() {
    log "SUCCESS" "$@"
}

# ============================================
# Backup Listing Functions
# ============================================

list_local_backups() {
    log_info "=========================================="
    log_info "Available Local Backups"
    log_info "=========================================="

    local found=0

    for backup_type in daily weekly monthly; do
        local dir_var="$(to_upper "$backup_type")_DIR"
        local dir="${!dir_var}"

        if [ ! -d "$dir" ]; then
            continue
        fi

        # macOS compatible: use ls -t for sorting by modification time
        local backups=()
        while IFS= read -r -d '' file; do
            backups+=("$file")
        done < <(find "$dir" -maxdepth 1 -name "*.tar.gz" -type f -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | tr '\n' '\0')

        if [ ${#backups[@]} -gt 0 ]; then
            echo ""
            echo "$(capitalize "$backup_type") Backups:"
            echo "----------------------------------------"

            for backup in "${backups[@]}"; do
                local filename=$(basename "$backup")
                local size=$(du -h "$backup" | cut -f1)
                local date=$(get_file_date "$backup")
                local checksum_file="${backup}.sha256"
                local checksum_status="✗"

                if [ -f "$checksum_file" ]; then
                    checksum_status="✓"
                fi

                printf "  %-50s  %8s  %s  [Checksum: %s]\n" "$filename" "$size" "$date" "$checksum_status"
                found=$((found + 1))
            done
        fi
    done

    if [ $found -eq 0 ]; then
        echo "No local backups found"
    else
        echo ""
        echo "Total: $found backup(s)"
    fi

    echo "=========================================="
}

list_s3_backups() {
    if [ "${S3_UPLOAD_ENABLED}" != "true" ]; then
        log_warn "S3 upload is disabled in configuration"
        return 1
    fi

    log_info "=========================================="
    log_info "Available S3 Backups"
    log_info "=========================================="

    if [ "${S3_UPLOAD_TOOL}" = "awscli" ]; then
        list_s3_with_aws_cli
    elif [ "${S3_UPLOAD_TOOL}" = "rclone" ]; then
        list_s3_with_rclone
    fi

    echo "=========================================="
}

list_s3_with_aws_cli() {
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI not found"
        return 1
    fi

    # Set credentials if provided
    if [ -n "${AWS_ACCESS_KEY_ID:-}" ]; then
        export AWS_ACCESS_KEY_ID
        export AWS_SECRET_ACCESS_KEY
    fi

    for backup_type in daily weekly monthly; do
        local s3_prefix="${S3_PREFIX}/${backup_type}/"

        echo ""
        echo "$(capitalize "$backup_type") Backups (S3):"
        echo "----------------------------------------"

        aws s3 ls "s3://${S3_BUCKET}/${s3_prefix}" --region "${S3_REGION}" 2>/dev/null | \
            grep "\.tar\.gz$" | sort -r | \
            awk '{printf "  %-50s  %8s %s  %s %s\n", $4, $3, $2, $1, $2}'
    done
}

list_s3_with_rclone() {
    if ! command -v rclone &> /dev/null; then
        log_error "rclone not found"
        return 1
    fi

    for backup_type in daily weekly monthly; do
        local remote_path="${RCLONE_REMOTE}:${S3_BUCKET}/${S3_PREFIX}/${backup_type}/"

        echo ""
        echo "$(capitalize "$backup_type") Backups (S3):"
        echo "----------------------------------------"

        rclone lsl "$remote_path" 2>/dev/null | grep "\.tar\.gz$" | sort -r
    done
}

# ============================================
# Download Functions
# ============================================

download_from_s3() {
    local backup_name="$1"
    local backup_type="$2"
    local dest_dir="${TEMP_DIR}/restore"

    mkdir -p "$dest_dir"

    log_info "Downloading from S3: ${backup_name}"

    if [ "${S3_UPLOAD_TOOL}" = "awscli" ]; then
        download_with_aws_cli "$backup_name" "$backup_type" "$dest_dir"
    elif [ "${S3_UPLOAD_TOOL}" = "rclone" ]; then
        download_with_rclone "$backup_name" "$backup_type" "$dest_dir"
    fi

    echo "${dest_dir}/${backup_name}"
}

download_with_aws_cli() {
    local backup_name="$1"
    local backup_type="$2"
    local dest_dir="$3"

    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI not found"
        exit 1
    fi

    # Set credentials if provided
    if [ -n "${AWS_ACCESS_KEY_ID:-}" ]; then
        export AWS_ACCESS_KEY_ID
        export AWS_SECRET_ACCESS_KEY
    fi

    local s3_path="s3://${S3_BUCKET}/${S3_PREFIX}/${backup_type}/${backup_name}"

    if aws s3 cp "$s3_path" "${dest_dir}/${backup_name}" --region "${S3_REGION}"; then
        log_success "Downloaded from S3"
    else
        log_error "Failed to download from S3"
        exit 1
    fi

    # Download checksum if available
    aws s3 cp "${s3_path}.sha256" "${dest_dir}/${backup_name}.sha256" --region "${S3_REGION}" 2>/dev/null || true
}

download_with_rclone() {
    local backup_name="$1"
    local backup_type="$2"
    local dest_dir="$3"

    if ! command -v rclone &> /dev/null; then
        log_error "rclone not found"
        exit 1
    fi

    local remote_path="${RCLONE_REMOTE}:${S3_BUCKET}/${S3_PREFIX}/${backup_type}/${backup_name}"

    if rclone copy "$remote_path" "$dest_dir/"; then
        log_success "Downloaded from S3"
    else
        log_error "Failed to download from S3"
        exit 1
    fi
}

# ============================================
# Verification Functions
# ============================================

verify_checksum() {
    local backup_file="$1"
    local checksum_file="${backup_file}.sha256"

    if [ ! -f "$checksum_file" ]; then
        log_warn "No checksum file found, skipping verification"
        return 0
    fi

    log_info "Verifying backup checksum..."

    cd "$(dirname "$backup_file")"
    if sha256sum -c "$(basename "$checksum_file")" &> /dev/null; then
        log_success "Checksum verification passed"
        cd - > /dev/null
        return 0
    else
        log_error "Checksum verification FAILED"
        cd - > /dev/null
        return 1
    fi
}

# ============================================
# Restore Functions
# ============================================

perform_restore() {
    local backup_file="$1"

    if [ ! -f "$backup_file" ]; then
        log_error "Backup file not found: $backup_file"
        exit 1
    fi

    # Verify checksum
    verify_checksum "$backup_file" || {
        if [ "$FORCE_RESTORE" = false ]; then
            log_error "Checksum verification failed. Use --force to restore anyway"
            exit 1
        else
            log_warn "Proceeding with restore despite failed checksum (--force)"
        fi
    }

    # Confirmation
    if [ "$SKIP_CONFIRMATION" = false ]; then
        echo ""
        log_warn "=========================================="
        log_warn "WARNING: This will REPLACE your current MySQL database!"
        log_warn "Current database: ${MYSQL_HOST}:${MYSQL_PORT}/${MYSQL_DATABASE}"
        log_warn "Restore from: $(basename $backup_file)"
        log_warn "=========================================="
        echo ""
        read -p "Are you sure you want to continue? (type 'yes' to confirm): " confirm

        if [ "$confirm" != "yes" ]; then
            log_info "Restore cancelled"
            exit 0
        fi
    fi

    # Extract backup
    local extract_dir="${TEMP_DIR}/restore-$(date +%s)"
    mkdir -p "$extract_dir"

    log_info "Extracting backup..."
    if tar -xzf "$backup_file" -C "$extract_dir"; then
        log_success "Backup extracted to: $extract_dir"
    else
        log_error "Failed to extract backup"
        exit 1
    fi

    # Find the backup directory inside the extracted archive
    local backup_dir=$(find "$extract_dir" -maxdepth 1 -type d -name "${BACKUP_PREFIX}-*" | head -n1)

    if [ -z "$backup_dir" ] || [ ! -d "$backup_dir" ]; then
        log_error "Cannot find backup directory in extracted archive"
        exit 1
    fi

    # Stop MySQL
    log_info "Stopping MySQL container..."
    ${DOCKER_CMD} stop ${MYSQL_HOST} || {
        log_error "Failed to stop MySQL container"
        exit 1
    }

    log_success "MySQL stopped"

    # Backup current data (just in case)
    local current_data_backup="${BACKUP_DIR}/pre-restore-backup-$(date +%Y%m%d-%H%M%S)"
    log_info "Creating safety backup of current data..."

    # Use MYSQL_DATA_DIR from config, fallback to auto-detection
    local mysql_data_dir="${MYSQL_DATA_DIR:-}"

    if [ -z "$mysql_data_dir" ] || [ ! -d "$mysql_data_dir" ]; then
        # Try to auto-detect from Docker container mounts
        log_info "MYSQL_DATA_DIR not set or invalid, trying to auto-detect..."
        mysql_data_dir=$(${DOCKER_CMD} inspect ${MYSQL_HOST} 2>/dev/null | \
            grep -A5 '"Mounts"' | grep -A2 '/var/lib/mysql' | grep '"Source"' | \
            cut -d'"' -f4 | head -n1)
    fi

    if [ -z "$mysql_data_dir" ] || [ ! -d "$mysql_data_dir" ]; then
        log_error "Cannot find MySQL data directory"
        log_error "Please set MYSQL_DATA_DIR in config/.env"
        exit 1
    fi

    log_info "Using MySQL data directory: $mysql_data_dir"

    if [ -d "$mysql_data_dir" ]; then
        cp -a "$mysql_data_dir" "$current_data_backup" || log_warn "Failed to create safety backup"
        log_info "Safety backup created: $current_data_backup"
    fi

    # Clear MySQL data directory
    log_info "Clearing MySQL data directory..."
    rm -rf "${mysql_data_dir}"/*
    log_success "Data directory cleared"

    # Copy restored data
    log_info "Copying restored data to MySQL data directory..."
    if cp -a "${backup_dir}"/* "${mysql_data_dir}/"; then
        log_success "Data copied successfully"
    else
        log_error "Failed to copy restored data"
        log_error "Your original data is backed up at: $current_data_backup"
        exit 1
    fi

    # Fix permissions
    log_info "Fixing permissions..."
    chown -R 999:999 "${mysql_data_dir}" 2>/dev/null || sudo chown -R 999:999 "${mysql_data_dir}"

    # Start MySQL
    log_info "Starting MySQL container..."
    ${DOCKER_CMD} start ${MYSQL_HOST} || {
        log_error "Failed to start MySQL container"
        log_error "Your original data is backed up at: $current_data_backup"
        exit 1
    }

    log_success "MySQL started"

    # Wait for MySQL to be ready
    log_info "Waiting for MySQL to be ready..."
    local retries=30
    while [ $retries -gt 0 ]; do
        if ${DOCKER_CMD} exec ${MYSQL_HOST} mysqladmin ping -h localhost -u root -p"${MYSQL_ROOT_PASSWORD}" &> /dev/null; then
            log_success "MySQL is ready"
            break
        fi
        retries=$((retries - 1))
        sleep 2
    done

    if [ $retries -eq 0 ]; then
        log_error "MySQL failed to become ready"
        log_error "Your original data is backed up at: $current_data_backup"
        exit 1
    fi

    # Verify restore
    log_info "Verifying database..."
    local table_count=$(${DOCKER_CMD} exec ${MYSQL_HOST} mysql -u root -p"${MYSQL_ROOT_PASSWORD}" \
        -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${MYSQL_DATABASE}';" -s -N 2>/dev/null || echo "0")

    log_success "=========================================="
    log_success "Restore completed successfully!"
    log_success "Database: ${MYSQL_DATABASE}"
    log_success "Tables: ${table_count}"
    log_success "Safety backup: $current_data_backup"
    log_success "=========================================="

    # Cleanup
    log_info "Cleaning up temporary files..."
    rm -rf "$extract_dir"
}

# ============================================
# Usage Function
# ============================================

usage() {
    cat << EOF
Usage: $(basename $0) [OPTIONS]

Octeth MySQL Restore Script
Restores MySQL database from XtraBackup backups

OPTIONS:
    -l, --list              List available local backups
    -L, --list-s3           List available S3 backups
    -f, --file FILE         Restore from specific local backup file
    -s, --s3 NAME TYPE      Restore from S3 backup (NAME and TYPE: daily|weekly|monthly)
    -F, --force             Force restore even if checksum verification fails
    -y, --yes               Skip confirmation prompt
    -h, --help              Display this help message

EXAMPLES:
    # List available local backups
    $(basename $0) --list

    # List S3 backups
    $(basename $0) --list-s3

    # Restore from local backup
    $(basename $0) --file /var/backups/octeth/daily/octeth-backup-2025-01-15_02-00-00.tar.gz

    # Restore from S3 backup
    $(basename $0) --s3 octeth-backup-2025-01-15_02-00-00.tar.gz daily

    # Force restore (skip checksum verification)
    $(basename $0) --file backup.tar.gz --force

    # Skip confirmation
    $(basename $0) --file backup.tar.gz --yes

EOF
    exit 0
}

# ============================================
# Main Function
# ============================================

main() {
    local list_local=false
    local list_s3=false
    local backup_file=""
    local s3_backup_name=""
    local s3_backup_type=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -l|--list)
                list_local=true
                shift
                ;;
            -L|--list-s3)
                list_s3=true
                shift
                ;;
            -f|--file)
                backup_file="$2"
                shift 2
                ;;
            -s|--s3)
                s3_backup_name="$2"
                s3_backup_type="$3"
                RESTORE_FROM_S3=true
                shift 3
                ;;
            -F|--force)
                FORCE_RESTORE=true
                shift
                ;;
            -y|--yes)
                SKIP_CONFIRMATION=true
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
    log_info "Octeth MySQL Restore"
    log_info "=========================================="

    # List operations
    if [ "$list_local" = true ]; then
        list_local_backups
        exit 0
    fi

    if [ "$list_s3" = true ]; then
        list_s3_backups
        exit 0
    fi

    # Restore operations
    if [ "$RESTORE_FROM_S3" = true ]; then
        if [ -z "$s3_backup_name" ] || [ -z "$s3_backup_type" ]; then
            log_error "Both backup name and type are required for S3 restore"
            usage
        fi

        backup_file=$(download_from_s3 "$s3_backup_name" "$s3_backup_type")
    fi

    if [ -z "$backup_file" ]; then
        log_error "No backup file specified"
        usage
    fi

    perform_restore "$backup_file"
}

# Run main function
main "$@"
