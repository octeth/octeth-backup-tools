#!/bin/bash
#
# Octeth Backup Tool - Installation Script
# Checks and installs all dependencies, sets up configuration
#
# Author: Octeth Team
# License: MIT
#

set -euo pipefail

# ============================================
# Colors for Output
# ============================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ============================================
# Global Variables
# ============================================

ENABLE_MYSQL=false
ENABLE_CLICKHOUSE=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================
# Logging Functions
# ============================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $@"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $@"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $@"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $@"
}

# ============================================
# Detection Functions
# ============================================

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$ID"
    elif [ -f /etc/redhat-release ]; then
        echo "rhel"
    elif [ -f /etc/debian_version ]; then
        echo "debian"
    else
        echo "unknown"
    fi
}

detect_package_manager() {
    if command -v apt-get &> /dev/null; then
        echo "apt"
    elif command -v yum &> /dev/null; then
        echo "yum"
    elif command -v dnf &> /dev/null; then
        echo "dnf"
    else
        echo "unknown"
    fi
}

# ============================================
# Engine Selection
# ============================================

select_engines() {
    # If engines were already set via CLI flags, skip the prompt
    if [ "$ENABLE_MYSQL" = true ] || [ "$ENABLE_CLICKHOUSE" = true ]; then
        return 0
    fi

    echo ""
    log_info "Which database engines do you want to back up?"
    echo ""
    echo "  1) MySQL only"
    echo "  2) ClickHouse only"
    echo "  3) Both MySQL and ClickHouse"
    echo ""
    read -p "Select [1-3]: " engine_choice

    case "$engine_choice" in
        1)
            ENABLE_MYSQL=true
            ENABLE_CLICKHOUSE=false
            ;;
        2)
            ENABLE_MYSQL=false
            ENABLE_CLICKHOUSE=true
            ;;
        3)
            ENABLE_MYSQL=true
            ENABLE_CLICKHOUSE=true
            ;;
        *)
            log_error "Invalid choice: $engine_choice"
            exit 1
            ;;
    esac

    echo ""
    if [ "$ENABLE_MYSQL" = true ] && [ "$ENABLE_CLICKHOUSE" = true ]; then
        log_info "Selected: MySQL + ClickHouse"
    elif [ "$ENABLE_MYSQL" = true ]; then
        log_info "Selected: MySQL only"
    else
        log_info "Selected: ClickHouse only"
    fi
}

# ============================================
# Dependency Check Functions
# ============================================

check_docker() {
    log_info "Checking Docker..."

    if command -v docker &> /dev/null; then
        local docker_version=$(docker --version | cut -d' ' -f3 | tr -d ',')
        log_success "Docker found: version $docker_version"
        return 0
    else
        log_error "Docker not found"
        log_error "Please install Docker: https://docs.docker.com/get-docker/"
        return 1
    fi
}

check_xtrabackup() {
    log_info "Checking Percona XtraBackup..."

    if command -v xtrabackup &> /dev/null; then
        local xb_version=$(xtrabackup --version 2>&1 | head -n1)
        log_success "XtraBackup found: $xb_version"
        return 0
    else
        log_warn "Percona XtraBackup not found"
        return 1
    fi
}

install_xtrabackup() {
    local os=$(detect_os)
    local pkg_mgr=$(detect_package_manager)

    log_info "Installing Percona XtraBackup 8.0..."

    case "$os" in
        ubuntu|debian)
            log_info "Installing for Ubuntu/Debian..."
            wget https://repo.percona.com/apt/percona-release_latest.$(lsb_release -sc)_all.deb
            sudo dpkg -i percona-release_latest.$(lsb_release -sc)_all.deb
            sudo apt-get update
            sudo percona-release enable-only tools release
            sudo apt-get install -y percona-xtrabackup-80
            rm percona-release_latest.$(lsb_release -sc)_all.deb
            ;;

        centos|rhel|rocky|almalinux)
            log_info "Installing for CentOS/RHEL/Rocky..."
            sudo yum install -y https://repo.percona.com/yum/percona-release-latest.noarch.rpm
            sudo percona-release enable-only tools release
            sudo yum install -y percona-xtrabackup-80
            ;;

        fedora)
            log_info "Installing for Fedora..."
            sudo dnf install -y https://repo.percona.com/yum/percona-release-latest.noarch.rpm
            sudo percona-release enable-only tools release
            sudo dnf install -y percona-xtrabackup-80
            ;;

        *)
            log_error "Unsupported OS: $os"
            log_error "Please install Percona XtraBackup manually:"
            log_error "https://www.percona.com/downloads/Percona-XtraBackup-LATEST/"
            return 1
            ;;
    esac

    if check_xtrabackup; then
        log_success "XtraBackup installed successfully"
        return 0
    else
        log_error "XtraBackup installation failed"
        return 1
    fi
}

check_compression_tools() {
    log_info "Checking compression tools..."

    local has_gzip=false
    local has_pigz=false

    if command -v gzip &> /dev/null; then
        log_success "gzip found"
        has_gzip=true
    fi

    if command -v pigz &> /dev/null; then
        log_success "pigz found (parallel compression)"
        has_pigz=true
    else
        log_warn "pigz not found (recommended for faster compression)"
    fi

    if [ "$has_gzip" = false ]; then
        log_error "gzip not found (required)"
        return 1
    fi

    return 0
}

install_pigz() {
    local pkg_mgr=$(detect_package_manager)

    log_info "Installing pigz..."

    case "$pkg_mgr" in
        apt)
            sudo apt-get install -y pigz
            ;;
        yum)
            sudo yum install -y pigz
            ;;
        dnf)
            sudo dnf install -y pigz
            ;;
        *)
            log_warn "Cannot install pigz automatically"
            return 1
            ;;
    esac

    log_success "pigz installed"
}

check_aws_cli() {
    log_info "Checking AWS CLI (optional)..."

    if command -v aws &> /dev/null; then
        local aws_version=$(aws --version 2>&1 | cut -d' ' -f1)
        log_success "AWS CLI found: $aws_version"
        return 0
    else
        log_warn "AWS CLI not found (required for S3 backups)"
        return 1
    fi
}

install_aws_cli() {
    log_info "Installing AWS CLI..."

    if command -v pip3 &> /dev/null; then
        sudo pip3 install awscli
    elif command -v pip &> /dev/null; then
        sudo pip install awscli
    else
        log_warn "pip not found, using package manager..."
        local pkg_mgr=$(detect_package_manager)

        case "$pkg_mgr" in
            apt)
                sudo apt-get install -y awscli
                ;;
            yum|dnf)
                sudo $pkg_mgr install -y awscli
                ;;
            *)
                log_error "Cannot install AWS CLI automatically"
                log_error "Please install manually: https://aws.amazon.com/cli/"
                return 1
                ;;
        esac
    fi

    if check_aws_cli; then
        log_success "AWS CLI installed successfully"
    fi
}

check_rclone() {
    log_info "Checking rclone (optional)..."

    if command -v rclone &> /dev/null; then
        local rclone_version=$(rclone --version | head -n1)
        log_success "rclone found: $rclone_version"
        return 0
    else
        log_warn "rclone not found (alternative to AWS CLI for S3)"
        return 1
    fi
}

# ============================================
# ClickHouse Dependency Check Functions
# ============================================

check_clickhouse_backup() {
    log_info "Checking clickhouse-backup..."

    # Read CH_HOST from .env if available
    local ch_host="oempro_clickhouse"
    if [ -f "${SCRIPT_DIR}/config/.env" ]; then
        local env_ch_host=$(grep "^CH_HOST=" "${SCRIPT_DIR}/config/.env" | cut -d'=' -f2)
        if [ -n "$env_ch_host" ]; then
            ch_host="$env_ch_host"
        fi
    fi

    # Check if ClickHouse container is running
    if ! docker ps --format '{{.Names}}' | grep -q "^${ch_host}$"; then
        log_warn "ClickHouse container '${ch_host}' is not running (skipping clickhouse-backup check)"
        return 1
    fi

    if docker exec "$ch_host" clickhouse-backup --version &> /dev/null; then
        local cb_version=$(docker exec "$ch_host" clickhouse-backup --version 2>&1 | head -n1)
        log_success "clickhouse-backup found in container: $cb_version"
        return 0
    else
        log_warn "clickhouse-backup not found inside container '${ch_host}'"
        return 1
    fi
}

install_clickhouse_backup_in_container() {
    local ch_host="oempro_clickhouse"
    if [ -f "${SCRIPT_DIR}/config/.env" ]; then
        local env_ch_host=$(grep "^CH_HOST=" "${SCRIPT_DIR}/config/.env" | cut -d'=' -f2)
        if [ -n "$env_ch_host" ]; then
            ch_host="$env_ch_host"
        fi
    fi

    if ! docker ps --format '{{.Names}}' | grep -q "^${ch_host}$"; then
        log_error "ClickHouse container '${ch_host}' is not running"
        log_error "Start the container first, then re-run this installer"
        return 1
    fi

    log_info "Installing clickhouse-backup in container '${ch_host}'..."

    # Detect architecture inside the container
    local arch=$(docker exec "$ch_host" uname -m 2>/dev/null)
    local binary_suffix="linux-amd64"
    if [ "$arch" = "aarch64" ] || [ "$arch" = "arm64" ]; then
        binary_suffix="linux-arm64"
    fi

    if docker exec "$ch_host" bash -c "
        curl -sL https://github.com/Altinity/clickhouse-backup/releases/latest/download/clickhouse-backup-${binary_suffix}.tar.gz | \
        tar xz -C /tmp && \
        mv /tmp/build/linux/*/clickhouse-backup /usr/local/bin/clickhouse-backup && \
        chmod +x /usr/local/bin/clickhouse-backup && \
        rm -rf /tmp/build
    " 2>&1; then
        log_success "clickhouse-backup installed in container"
        return 0
    else
        log_error "Failed to install clickhouse-backup in container"
        log_error "You can install it manually:"
        log_error "  docker exec ${ch_host} bash -c 'curl -sL https://github.com/Altinity/clickhouse-backup/releases/latest/download/clickhouse-backup-${binary_suffix}.tar.gz | tar xz -C /usr/local/bin'"
        return 1
    fi
}

# ============================================
# Configuration Setup
# ============================================

setup_configuration() {
    log_info "Setting up configuration files..."

    # Copy .env file if it doesn't exist
    if [ ! -f "${SCRIPT_DIR}/config/.env" ]; then
        cp "${SCRIPT_DIR}/config/.env.example" "${SCRIPT_DIR}/config/.env"
        log_success "Created config/.env from example"
        if [ "$ENABLE_MYSQL" = true ] && [ "$ENABLE_CLICKHOUSE" = true ]; then
            log_warn "Please edit config/.env with your MySQL and ClickHouse credentials"
        elif [ "$ENABLE_MYSQL" = true ]; then
            log_warn "Please edit config/.env with your MySQL credentials"
        else
            log_warn "Please edit config/.env with your ClickHouse credentials"
        fi
    else
        log_info "config/.env already exists"
    fi

    # Copy backup.conf if it doesn't exist
    if [ ! -f "${SCRIPT_DIR}/config/backup.conf" ]; then
        cp "${SCRIPT_DIR}/config/backup.conf.example" "${SCRIPT_DIR}/config/backup.conf"
        log_success "Created config/backup.conf from example"
    else
        log_info "config/backup.conf already exists"
    fi

    # Create necessary directories
    log_info "Creating directories..."
    sudo mkdir -p /var/log

    # MySQL directories
    if [ "$ENABLE_MYSQL" = true ]; then
        local backup_dir="/var/backups/octeth"
        if [ -f "${SCRIPT_DIR}/config/.env" ]; then
            local env_dir=$(grep "^BACKUP_DIR=" "${SCRIPT_DIR}/config/.env" | cut -d'=' -f2)
            if [ -n "$env_dir" ]; then
                backup_dir="$env_dir"
            fi
        fi

        sudo mkdir -p "$backup_dir"/{daily,weekly,monthly}
        sudo touch /var/log/octeth-backup.log
        sudo chmod 666 /var/log/octeth-backup.log
        log_success "MySQL backup directories created: $backup_dir"
    fi

    # ClickHouse directories
    if [ "$ENABLE_CLICKHOUSE" = true ]; then
        local ch_backup_dir="/var/backups/octeth-ch"
        if [ -f "${SCRIPT_DIR}/config/.env" ]; then
            local env_ch_dir=$(grep "^CH_BACKUP_DIR=" "${SCRIPT_DIR}/config/.env" | cut -d'=' -f2)
            if [ -n "$env_ch_dir" ]; then
                ch_backup_dir="$env_ch_dir"
            fi
        fi

        sudo mkdir -p "$ch_backup_dir"/{daily,weekly,monthly}
        sudo touch /var/log/octeth-ch-backup.log
        sudo chmod 666 /var/log/octeth-ch-backup.log
        log_success "ClickHouse backup directories created: $ch_backup_dir"
    fi
}

# ============================================
# Cron Setup
# ============================================

setup_cron_for_engine() {
    local engine="$1"
    local backup_script="$2"
    local cleanup_script="$3"
    local log_file="$4"
    local default_backup_time="$5"
    local default_cleanup_time="$6"

    log_info "Setting up ${engine} cron jobs..."

    local backup_script_name=$(basename "$backup_script")
    local cleanup_script_name=$(basename "$cleanup_script")

    # Check if cron job already exists
    local existing_cron=""
    if crontab -l >/dev/null 2>&1; then
        existing_cron=$(crontab -l 2>/dev/null | grep "$backup_script_name" || true)
    fi

    if [ -n "$existing_cron" ]; then
        log_info "Found existing ${engine} cron job:"
        echo "  $existing_cron"
        read -p "Do you want to replace it? (y/n): " replace_cron
        if [ "$replace_cron" != "y" ] && [ "$replace_cron" != "Y" ]; then
            log_info "Keeping existing ${engine} cron job"
            return 0
        fi
        # Remove existing entries for this engine
        crontab -l 2>/dev/null | grep -v "$backup_script_name" | grep -v "$cleanup_script_name" | crontab - || true
    fi

    local cron_schedule="$default_backup_time"

    echo ""
    log_info "Default ${engine} backup schedule: ${default_backup_time} (cron format)"
    read -p "Do you want to use the default schedule? (y/n): " use_default

    if [ "$use_default" != "y" ] && [ "$use_default" != "Y" ]; then
        echo ""
        echo "Cron format: minute hour day month weekday"
        echo "Examples:"
        echo "  0 2 * * *     - Daily at 2:00 AM"
        echo "  0 */6 * * *   - Every 6 hours"
        echo "  0 3 * * 0     - Weekly on Sunday at 3:00 AM"
        echo ""
        read -p "Enter cron schedule for ${engine} backup: " cron_schedule
    fi

    # Add backup cron job
    (crontab -l 2>/dev/null || true; echo "$cron_schedule $backup_script >> $log_file 2>&1") | crontab -

    if crontab -l 2>/dev/null | grep -q "$backup_script_name"; then
        log_success "${engine} backup cron job added: $cron_schedule"
    else
        log_error "Failed to add ${engine} backup cron job"
        return 1
    fi

    # Add cleanup job
    local existing_cleanup=""
    if crontab -l >/dev/null 2>&1; then
        existing_cleanup=$(crontab -l 2>/dev/null | grep "$cleanup_script_name" || true)
    fi

    if [ -z "$existing_cleanup" ]; then
        (crontab -l 2>/dev/null || true; echo "$default_cleanup_time $cleanup_script >> $log_file 2>&1") | crontab -

        if crontab -l 2>/dev/null | grep -q "$cleanup_script_name"; then
            log_success "${engine} cleanup cron job added: $default_cleanup_time"
        else
            log_warn "Failed to add ${engine} cleanup cron job"
        fi
    else
        log_info "${engine} cleanup cron job already exists"
    fi
}

setup_cron() {
    if [ "$ENABLE_MYSQL" = true ]; then
        setup_cron_for_engine \
            "MySQL" \
            "${SCRIPT_DIR}/bin/octeth-backup.sh" \
            "${SCRIPT_DIR}/bin/octeth-cleanup.sh" \
            "/var/log/octeth-backup.log" \
            "0 2 * * *" \
            "30 2 * * *"
    fi

    if [ "$ENABLE_CLICKHOUSE" = true ]; then
        setup_cron_for_engine \
            "ClickHouse" \
            "${SCRIPT_DIR}/bin/octeth-ch-backup.sh" \
            "${SCRIPT_DIR}/bin/octeth-ch-cleanup.sh" \
            "/var/log/octeth-ch-backup.log" \
            "0 3 * * *" \
            "30 3 * * *"
    fi
}

# ============================================
# Configuration Wizard
# ============================================

run_config_wizard() {
    log_info "=========================================="
    log_info "Configuration Wizard"
    log_info "=========================================="

    local env_file="${SCRIPT_DIR}/config/.env"

    if [ ! -f "$env_file" ]; then
        cp "${SCRIPT_DIR}/config/.env.example" "$env_file"
    fi

    # MySQL settings
    if [ "$ENABLE_MYSQL" = true ]; then
        echo ""
        log_info "--- MySQL Configuration ---"
        echo ""

        read -p "MySQL container name [oempro_mysql]: " mysql_host
        mysql_host=${mysql_host:-oempro_mysql}
        sed -i "s/^MYSQL_HOST=.*/MYSQL_HOST=$mysql_host/" "$env_file"

        read -p "MySQL root password: " -s mysql_root_password
        echo ""
        sed -i "s/^MYSQL_ROOT_PASSWORD=.*/MYSQL_ROOT_PASSWORD=$mysql_root_password/" "$env_file"

        read -p "MySQL database name [oempro]: " mysql_database
        mysql_database=${mysql_database:-oempro}
        sed -i "s/^MYSQL_DATABASE=.*/MYSQL_DATABASE=$mysql_database/" "$env_file"

        read -p "MySQL data directory on host [/opt/oempro/_dockerfiles/mysql/data_v8]: " mysql_data_dir
        mysql_data_dir=${mysql_data_dir:-/opt/oempro/_dockerfiles/mysql/data_v8}
        sed -i "s|^MYSQL_DATA_DIR=.*|MYSQL_DATA_DIR=$mysql_data_dir|" "$env_file"
    fi

    # ClickHouse settings
    if [ "$ENABLE_CLICKHOUSE" = true ]; then
        echo ""
        log_info "--- ClickHouse Configuration ---"
        echo ""

        read -p "ClickHouse container name [oempro_clickhouse]: " ch_host
        ch_host=${ch_host:-oempro_clickhouse}
        sed -i "s/^CH_HOST=.*/CH_HOST=$ch_host/" "$env_file"

        read -p "ClickHouse user [default]: " ch_user
        ch_user=${ch_user:-default}
        sed -i "s/^CH_USER=.*/CH_USER=$ch_user/" "$env_file"

        read -p "ClickHouse password (leave empty for none): " -s ch_password
        echo ""
        sed -i "s/^CH_PASSWORD=.*/CH_PASSWORD=$ch_password/" "$env_file"

        read -p "ClickHouse database name [oempro]: " ch_database
        ch_database=${ch_database:-oempro}
        sed -i "s/^CH_DATABASE=.*/CH_DATABASE=$ch_database/" "$env_file"

        read -p "ClickHouse data directory on host (leave empty to use docker cp): " ch_data_dir
        sed -i "s|^CH_DATA_DIR=.*|CH_DATA_DIR=$ch_data_dir|" "$env_file"
    fi

    # Cloud storage settings
    echo ""
    log_info "--- Cloud Storage Configuration ---"
    echo ""
    read -p "Enable cloud storage backups? (y/n) [n]: " enable_cloud
    if [ "$enable_cloud" = "y" ] || [ "$enable_cloud" = "Y" ]; then
        echo ""
        echo "  1) AWS S3"
        echo "  2) Google Cloud Storage"
        echo "  3) Cloudflare R2"
        echo ""
        read -p "Select cloud provider [1-3]: " cloud_choice

        case "$cloud_choice" in
            1)
                sed -i "s/^CLOUD_STORAGE_PROVIDER=.*/CLOUD_STORAGE_PROVIDER=s3/" "$env_file"

                read -p "S3 bucket name: " s3_bucket
                sed -i "s/^S3_BUCKET=.*/S3_BUCKET=$s3_bucket/" "$env_file"

                read -p "S3 region [us-east-1]: " s3_region
                s3_region=${s3_region:-us-east-1}
                sed -i "s/^S3_REGION=.*/S3_REGION=$s3_region/" "$env_file"

                read -p "AWS Access Key ID: " aws_access_key
                sed -i "s/^AWS_ACCESS_KEY_ID=.*/AWS_ACCESS_KEY_ID=$aws_access_key/" "$env_file"

                read -p "AWS Secret Access Key: " -s aws_secret_key
                echo ""
                sed -i "s|^AWS_SECRET_ACCESS_KEY=.*|AWS_SECRET_ACCESS_KEY=$aws_secret_key|" "$env_file"
                ;;
            2)
                sed -i "s/^CLOUD_STORAGE_PROVIDER=.*/CLOUD_STORAGE_PROVIDER=gcs/" "$env_file"

                read -p "GCS bucket name: " gcs_bucket
                sed -i "s/^GCS_BUCKET=.*/GCS_BUCKET=$gcs_bucket/" "$env_file"

                read -p "GCS project ID (optional): " gcs_project
                sed -i "s/^GCS_PROJECT_ID=.*/GCS_PROJECT_ID=$gcs_project/" "$env_file"

                read -p "Path to service account JSON (optional): " gcs_creds
                sed -i "s|^GOOGLE_APPLICATION_CREDENTIALS=.*|GOOGLE_APPLICATION_CREDENTIALS=$gcs_creds|" "$env_file"
                ;;
            3)
                sed -i "s/^CLOUD_STORAGE_PROVIDER=.*/CLOUD_STORAGE_PROVIDER=r2/" "$env_file"

                read -p "R2 bucket name: " r2_bucket
                sed -i "s/^R2_BUCKET=.*/R2_BUCKET=$r2_bucket/" "$env_file"

                read -p "R2 account ID: " r2_account
                sed -i "s/^R2_ACCOUNT_ID=.*/R2_ACCOUNT_ID=$r2_account/" "$env_file"

                read -p "R2 Access Key ID: " r2_access_key
                sed -i "s/^R2_ACCESS_KEY_ID=.*/R2_ACCESS_KEY_ID=$r2_access_key/" "$env_file"

                read -p "R2 Secret Access Key: " -s r2_secret_key
                echo ""
                sed -i "s|^R2_SECRET_ACCESS_KEY=.*|R2_SECRET_ACCESS_KEY=$r2_secret_key|" "$env_file"
                ;;
        esac
    fi

    echo ""
    log_success "Configuration saved to $env_file"
}

# ============================================
# Install Dependencies
# ============================================

install_dependencies() {
    log_info "Checking dependencies..."
    echo ""

    check_docker || exit 1

    # MySQL dependencies
    if [ "$ENABLE_MYSQL" = true ]; then
        echo ""
        log_info "--- MySQL Dependencies ---"
        if ! check_xtrabackup; then
            read -p "Install Percona XtraBackup? (y/n): " install_xb
            if [ "$install_xb" = "y" ] || [ "$install_xb" = "Y" ]; then
                install_xtrabackup || exit 1
            else
                log_error "XtraBackup is required for MySQL backups"
                exit 1
            fi
        fi
    fi

    # ClickHouse dependencies
    if [ "$ENABLE_CLICKHOUSE" = true ]; then
        echo ""
        log_info "--- ClickHouse Dependencies ---"
        echo ""
        echo "How do you want to run clickhouse-backup?"
        echo ""
        echo "  1) Sidecar container (recommended)"
        echo "     Uses the official altinity/clickhouse-backup Docker image."
        echo "     Keeps the ClickHouse container clean and untouched."
        echo "     Requires CH_DATA_DIR to be set (ClickHouse data volume path on host)."
        echo ""
        echo "  2) Internal (inside the ClickHouse container)"
        echo "     Installs clickhouse-backup binary inside the ClickHouse container."
        echo "     Simpler but modifies the container (lost on rebuild)."
        echo ""
        read -p "Select [1-2] (default: 1): " ch_mode_choice
        ch_mode_choice=${ch_mode_choice:-1}

        if [ "$ch_mode_choice" = "2" ]; then
            # Internal mode
            log_info "Selected: internal mode"
            if [ -f "${SCRIPT_DIR}/config/.env" ]; then
                sed -i "s/^CH_BACKUP_MODE=.*/CH_BACKUP_MODE=internal/" "${SCRIPT_DIR}/config/.env" 2>/dev/null || true
            fi

            if ! check_clickhouse_backup; then
                read -p "Install clickhouse-backup inside the ClickHouse container? (y/n): " install_cb
                if [ "$install_cb" = "y" ] || [ "$install_cb" = "Y" ]; then
                    install_clickhouse_backup_in_container || log_warn "clickhouse-backup installation failed (you can install it later)"
                else
                    log_warn "clickhouse-backup is required for ClickHouse backups"
                    log_warn "You can install it later with: sudo ./install.sh --deps-only --clickhouse"
                fi
            fi
        else
            # Sidecar mode (default)
            log_info "Selected: sidecar mode"
            if [ -f "${SCRIPT_DIR}/config/.env" ]; then
                sed -i "s/^CH_BACKUP_MODE=.*/CH_BACKUP_MODE=sidecar/" "${SCRIPT_DIR}/config/.env" 2>/dev/null || true
            fi

            # Auto-detect CH_DATA_DIR from container mounts
            local detected_data_dir=$(docker inspect ${CH_HOST:-oempro_clickhouse} --format '{{range .Mounts}}{{if eq .Destination "/var/lib/clickhouse"}}{{.Source}}{{end}}{{end}}' 2>/dev/null || echo "")

            if [ -n "$detected_data_dir" ]; then
                log_success "Auto-detected ClickHouse data directory: ${detected_data_dir}"
                read -p "Use this path for CH_DATA_DIR? (y/n) [y]: " use_detected
                use_detected=${use_detected:-y}
                if [ "$use_detected" = "y" ] || [ "$use_detected" = "Y" ]; then
                    if [ -f "${SCRIPT_DIR}/config/.env" ]; then
                        sed -i "s|^CH_DATA_DIR=.*|CH_DATA_DIR=${detected_data_dir}|" "${SCRIPT_DIR}/config/.env" 2>/dev/null || true
                    fi
                fi
            else
                log_warn "Could not auto-detect ClickHouse data directory"
                log_warn "Please set CH_DATA_DIR in config/.env manually"
                log_warn "Find it with: docker inspect ${CH_HOST:-oempro_clickhouse} --format '{{range .Mounts}}{{if eq .Destination \"/var/lib/clickhouse\"}}{{.Source}}{{end}}{{end}}'"
            fi

            # Pull the sidecar image
            local ch_image="${CH_BACKUP_IMAGE:-altinity/clickhouse-backup:latest}"
            log_info "Pulling clickhouse-backup image: ${ch_image}"
            if docker pull "${ch_image}"; then
                log_success "Image pulled: ${ch_image}"
            else
                log_warn "Failed to pull ${ch_image} (you can pull it later)"
            fi
        fi
    fi

    # Shared dependencies
    echo ""
    log_info "--- Shared Dependencies ---"

    check_compression_tools || exit 1

    if ! command -v pigz &> /dev/null; then
        read -p "Install pigz for faster compression? (recommended) (y/n): " install_pg
        if [ "$install_pg" = "y" ] || [ "$install_pg" = "Y" ]; then
            install_pigz
        fi
    fi

    if ! check_aws_cli; then
        read -p "Install AWS CLI for S3/R2 cloud backups? (optional) (y/n): " install_aws
        if [ "$install_aws" = "y" ] || [ "$install_aws" = "Y" ]; then
            install_aws_cli
        fi
    fi

    echo ""
    log_success "All required dependencies are installed"
}

# ============================================
# Main Installation
# ============================================

main() {
    echo ""
    log_info "=========================================="
    log_info "Octeth Backup Tools - Installation"
    log_info "=========================================="
    echo ""

    local install_deps=false
    local setup_config=false
    local setup_cron_job=false
    local run_wizard=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --mysql)
                ENABLE_MYSQL=true
                shift
                ;;
            --clickhouse)
                ENABLE_CLICKHOUSE=true
                shift
                ;;
            --deps-only)
                install_deps=true
                shift
                ;;
            --config-only)
                setup_config=true
                shift
                ;;
            --cron-only)
                setup_cron_job=true
                shift
                ;;
            --wizard)
                run_wizard=true
                shift
                ;;
            --help)
                cat << EOF
Usage: $(basename $0) [OPTIONS]

ENGINE SELECTION:
    --mysql         Install MySQL backup tools only
    --clickhouse    Install ClickHouse backup tools only
                    (combine both flags for both engines)

OPTIONS:
    --deps-only     Install dependencies only
    --config-only   Setup configuration only
    --cron-only     Setup cron jobs only
    --wizard        Run interactive configuration wizard
    --help          Display this help message

EXAMPLES:
    # Full installation (interactive engine selection)
    sudo ./install.sh

    # MySQL only
    sudo ./install.sh --mysql

    # ClickHouse only
    sudo ./install.sh --clickhouse

    # Both engines
    sudo ./install.sh --mysql --clickhouse

    # Install only ClickHouse dependencies
    sudo ./install.sh --deps-only --clickhouse

    # Run wizard for MySQL setup
    sudo ./install.sh --wizard --mysql

Without --mysql or --clickhouse, you will be prompted to choose.
Without other options, performs full installation (deps + config + cron).

EOF
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                log_error "Use --help for usage information"
                exit 1
                ;;
        esac
    done

    # If no specific action options, do full installation
    if [ "$install_deps" = false ] && [ "$setup_config" = false ] && [ "$setup_cron_job" = false ] && [ "$run_wizard" = false ]; then
        install_deps=true
        setup_config=true
        setup_cron_job=true
    fi

    # Prompt for engine selection if not specified via flags
    select_engines

    # Install dependencies
    if [ "$install_deps" = true ]; then
        install_dependencies
        echo ""
    fi

    # Setup configuration
    if [ "$setup_config" = true ]; then
        setup_configuration
        echo ""
    fi

    # Run wizard
    if [ "$run_wizard" = true ]; then
        run_config_wizard
        echo ""
    fi

    # Setup cron
    if [ "$setup_cron_job" = true ]; then
        read -p "Setup cron jobs for automatic backups? (y/n): " setup_cron_answer
        if [ "$setup_cron_answer" = "y" ] || [ "$setup_cron_answer" = "Y" ]; then
            setup_cron
        fi
        echo ""
    fi

    # Summary
    log_success "=========================================="
    log_success "Installation Complete!"
    log_success "=========================================="
    echo ""
    log_info "Next steps:"
    local step=1

    if [ "$ENABLE_MYSQL" = true ] && [ "$ENABLE_CLICKHOUSE" = true ]; then
        echo "  ${step}. Edit config/.env with your MySQL and ClickHouse credentials"
        step=$((step + 1))
    elif [ "$ENABLE_MYSQL" = true ]; then
        echo "  ${step}. Edit config/.env with your MySQL credentials"
        step=$((step + 1))
    else
        echo "  ${step}. Edit config/.env with your ClickHouse credentials"
        step=$((step + 1))
    fi

    if [ "$ENABLE_MYSQL" = true ]; then
        echo "  ${step}. Test MySQL backup: ./bin/octeth-backup.sh"
        step=$((step + 1))
    fi

    if [ "$ENABLE_CLICKHOUSE" = true ]; then
        echo "  ${step}. Test ClickHouse backup: ./bin/octeth-ch-backup.sh"
        step=$((step + 1))
    fi

    echo "  ${step}. View cleanup policy: ./bin/octeth-cleanup.sh --stats"
    echo ""
    log_info "Documentation: See README.md"
    echo ""
}

# Run main function
main "$@"
