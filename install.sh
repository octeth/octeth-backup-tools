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
# Configuration Setup
# ============================================

setup_configuration() {
    log_info "Setting up configuration files..."

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # Copy .env file if it doesn't exist
    if [ ! -f "${SCRIPT_DIR}/config/.env" ]; then
        cp "${SCRIPT_DIR}/config/.env.example" "${SCRIPT_DIR}/config/.env"
        log_success "Created config/.env from example"
        log_warn "Please edit config/.env with your MySQL credentials"
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

    # Read BACKUP_DIR from .env if it exists
    local backup_dir="/var/backups/octeth"
    if [ -f "${SCRIPT_DIR}/config/.env" ]; then
        backup_dir=$(grep "^BACKUP_DIR=" "${SCRIPT_DIR}/config/.env" | cut -d'=' -f2)
    fi

    sudo mkdir -p "$backup_dir"/{daily,weekly,monthly}
    sudo mkdir -p /var/log
    sudo touch /var/log/octeth-backup.log
    sudo chmod 666 /var/log/octeth-backup.log

    log_success "Directories created"
}

# ============================================
# Cron Setup
# ============================================

setup_cron() {
    local script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bin/octeth-backup.sh"

    log_info "Setting up cron job..."

    # Check if cron job already exists
    local existing_cron=""
    if crontab -l >/dev/null 2>&1; then
        existing_cron=$(crontab -l 2>/dev/null | grep "octeth-backup.sh" || true)
    fi

    if [ -n "$existing_cron" ]; then
        log_info "Found existing cron job:"
        echo "  $existing_cron"
        read -p "Do you want to replace it? (y/n): " replace_cron
        if [ "$replace_cron" != "y" ] && [ "$replace_cron" != "Y" ]; then
            log_info "Keeping existing cron job"
            return 0
        fi
        # Remove existing octeth-backup.sh entries
        crontab -l 2>/dev/null | grep -v "octeth-backup.sh" | crontab - || true
    fi

    # Default: Run daily at 2 AM
    local cron_schedule="0 2 * * *"

    echo ""
    log_info "Default schedule: Daily at 2:00 AM"
    read -p "Do you want to use the default schedule? (y/n): " use_default

    if [ "$use_default" != "y" ] && [ "$use_default" != "Y" ]; then
        echo ""
        echo "Cron format: minute hour day month weekday"
        echo "Examples:"
        echo "  0 2 * * *     - Daily at 2:00 AM"
        echo "  0 */6 * * *   - Every 6 hours"
        echo "  0 3 * * 0     - Weekly on Sunday at 3:00 AM"
        echo ""
        read -p "Enter cron schedule: " cron_schedule
    fi

    # Add cron job
    (crontab -l 2>/dev/null || true; echo "$cron_schedule $script_path >> /var/log/octeth-backup.log 2>&1") | crontab -

    # Verify the cron job was added
    if crontab -l 2>/dev/null | grep -q "octeth-backup.sh"; then
        log_success "Cron job added: $cron_schedule"
    else
        log_error "Failed to add cron job"
        return 1
    fi

    # Also add cleanup job (run after backup)
    local cleanup_schedule="30 2 * * *"  # 30 minutes after backup
    local cleanup_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bin/octeth-cleanup.sh"

    local existing_cleanup=""
    if crontab -l >/dev/null 2>&1; then
        existing_cleanup=$(crontab -l 2>/dev/null | grep "octeth-cleanup.sh" || true)
    fi

    if [ -z "$existing_cleanup" ]; then
        (crontab -l 2>/dev/null || true; echo "$cleanup_schedule $cleanup_path >> /var/log/octeth-backup.log 2>&1") | crontab -

        # Verify cleanup job was added
        if crontab -l 2>/dev/null | grep -q "octeth-cleanup.sh"; then
            log_success "Cleanup cron job added: $cleanup_schedule"
        else
            log_warn "Failed to add cleanup cron job"
        fi
    else
        log_info "Cleanup cron job already exists"
    fi
}

# ============================================
# Configuration Wizard
# ============================================

run_config_wizard() {
    log_info "=========================================="
    log_info "Configuration Wizard"
    log_info "=========================================="

    local env_file="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config/.env"

    # MySQL settings
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

    # S3 settings
    echo ""
    read -p "Enable S3 backups? (y/n) [n]: " enable_s3
    if [ "$enable_s3" = "y" ] || [ "$enable_s3" = "Y" ]; then
        sed -i "s/^S3_UPLOAD_ENABLED=.*/S3_UPLOAD_ENABLED=true/" "$env_file"

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
    fi

    log_success "Configuration saved to $env_file"
}

# ============================================
# Main Installation
# ============================================

main() {
    echo ""
    log_info "=========================================="
    log_info "Octeth Backup Tool - Installation"
    log_info "=========================================="
    echo ""

    local install_deps=false
    local setup_config=false
    local setup_cron_job=false
    local run_wizard=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
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

OPTIONS:
    --deps-only     Install dependencies only
    --config-only   Setup configuration only
    --cron-only     Setup cron jobs only
    --wizard        Run configuration wizard
    --help          Display this help message

Without options, performs full installation (deps + config + cron)

EOF
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    # If no specific options, do full installation
    if [ "$install_deps" = false ] && [ "$setup_config" = false ] && [ "$setup_cron_job" = false ] && [ "$run_wizard" = false ]; then
        install_deps=true
        setup_config=true
        setup_cron_job=true
    fi

    # Check dependencies
    if [ "$install_deps" = true ]; then
        log_info "Checking dependencies..."
        echo ""

        check_docker || exit 1

        if ! check_xtrabackup; then
            read -p "Install Percona XtraBackup? (y/n): " install_xb
            if [ "$install_xb" = "y" ] || [ "$install_xb" = "Y" ]; then
                install_xtrabackup || exit 1
            else
                log_error "XtraBackup is required"
                exit 1
            fi
        fi

        check_compression_tools || exit 1

        if ! command -v pigz &> /dev/null; then
            read -p "Install pigz for faster compression? (recommended) (y/n): " install_pg
            if [ "$install_pg" = "y" ] || [ "$install_pg" = "Y" ]; then
                install_pigz
            fi
        fi

        if ! check_aws_cli; then
            read -p "Install AWS CLI for S3 backups? (optional) (y/n): " install_aws
            if [ "$install_aws" = "y" ] || [ "$install_aws" = "Y" ]; then
                install_aws_cli
            fi
        fi

        log_success "All required dependencies are installed"
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
        read -p "Setup cron job for automatic backups? (y/n): " setup_cron_answer
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
    echo "  1. Edit config/.env with your MySQL credentials"
    echo "  2. Test backup: ./bin/octeth-backup.sh"
    echo "  3. List backups: ./bin/octeth-restore.sh --list"
    echo "  4. View cleanup policy: ./bin/octeth-cleanup.sh --stats"
    echo ""
    log_info "Documentation: See README.md"
    echo ""
}

# Run main function
main "$@"
