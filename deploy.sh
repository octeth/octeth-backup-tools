#!/bin/bash
#
# deploy.sh - Deploy octeth-backup-tools to a server via rsync
#
# Uploads the project with rsync's delta transfer (only changed files / changed
# blocks are sent) and keeps a timestamped backup of every file it overwrites or
# deletes on the server (rsync --backup), so any deploy can be rolled back.
#
# NOTE: This intentionally does NOT use rsync --append. --append only works for
# files that grow (e.g. logs); for source code it would corrupt files when their
# contents change in place. Default delta transfer is what "upload only changed
# files" actually means. Use --partial (below) if you need resumable transfers.
#
# By default the live secret config (config/.env, config/backup.conf) is NOT
# deployed, so the server's credentials are never clobbered. Use --include-env
# to push them for a one-off (the old versions are saved to the backup dir).
#

set -euo pipefail

# ============================================
# Defaults (override via environment or flags)
# ============================================

DEPLOY_USER="${DEPLOY_USER:-root}"
DEPLOY_HOST="${DEPLOY_HOST:-}"
DEPLOY_PATH="${DEPLOY_PATH:-/opt/octeth-backup-tools}"
SSH_PORT="${SSH_PORT:-22}"

DRY_RUN=false
INCLUDE_ENV=false
DELETE=false
PARTIAL=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================
# Usage
# ============================================

usage() {
    cat << EOF
Usage: $(basename "$0") --host HOST [OPTIONS]

Deploy octeth-backup-tools to a server with rsync (delta transfer + backups).

OPTIONS:
    -H, --host HOST       Target SSH host (required; or set DEPLOY_HOST)
    -u, --user USER       SSH user (default: ${DEPLOY_USER})
    -p, --path PATH       Remote install path (default: ${DEPLOY_PATH})
    -P, --port PORT       SSH port (default: ${SSH_PORT})
    -n, --dry-run         Show what would change without uploading (recommended first)
        --include-env     Also deploy config/.env and config/backup.conf (overwrites server secrets)
        --delete          Remove server files that no longer exist locally (off by default)
        --partial         Keep partially transferred files (resumable over flaky links)
    -h, --help            Show this help

ENVIRONMENT:
    DEPLOY_HOST, DEPLOY_USER, DEPLOY_PATH, SSH_PORT

EXAMPLES:
    # Preview a deploy (no changes made)
    DEPLOY_HOST=my-server $(basename "$0") --dry-run

    # Deploy code (leaves server config/.env untouched)
    $(basename "$0") --host my-server

    # One-off: also push the local config/.env to the server
    $(basename "$0") --host my-server --include-env
EOF
    exit "${1:-0}"
}

# ============================================
# Argument parsing
# ============================================

while [[ $# -gt 0 ]]; do
    case "$1" in
        -H|--host)        DEPLOY_HOST="$2"; shift 2 ;;
        -u|--user)        DEPLOY_USER="$2"; shift 2 ;;
        -p|--path)        DEPLOY_PATH="$2"; shift 2 ;;
        -P|--port)        SSH_PORT="$2"; shift 2 ;;
        -n|--dry-run)     DRY_RUN=true; shift ;;
        --include-env)    INCLUDE_ENV=true; shift ;;
        --delete)         DELETE=true; shift ;;
        --partial)        PARTIAL=true; shift ;;
        -h|--help)        usage 0 ;;
        *) echo "Unknown option: $1" >&2; usage 1 ;;
    esac
done

if [ -z "$DEPLOY_HOST" ]; then
    echo "ERROR: target host not set. Use --host or set DEPLOY_HOST." >&2
    usage 1
fi

if ! command -v rsync &> /dev/null; then
    echo "ERROR: rsync is not installed locally." >&2
    exit 1
fi

# Normalise (strip any trailing slash) and derive the server-side backup dir
DEPLOY_PATH="${DEPLOY_PATH%/}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${DEPLOY_PATH}.backups/${TIMESTAMP}"

# ============================================
# Build rsync options
# ============================================

RSYNC_OPTS=(
    -a                       # archive: preserve perms, times, symlinks, etc.
    --human-readable
    --itemize-changes        # print exactly which files change
    --compress               # compress data in transit
    --backup                 # keep a copy of every replaced/deleted file...
    --backup-dir="$BACKUP_DIR"  # ...in a timestamped dir OUTSIDE the deploy tree
    # Never deploy local-only / runtime / VCS clutter:
    --exclude='.git/'
    --exclude='.github/'
    --exclude='.gitignore'
    --exclude='.DS_Store'
    --exclude='.claude/'
    --exclude='logs/'
    --exclude='*.log'
    --exclude='*.lock'
    --exclude='*.tmp'
    --exclude='xtrabackup_backupfiles/'
)

# Protect the server's live secret config unless explicitly overridden
if [ "$INCLUDE_ENV" = false ]; then
    RSYNC_OPTS+=(--exclude='config/.env' --exclude='config/backup.conf')
fi

[ "$DRY_RUN" = true ] && RSYNC_OPTS+=(--dry-run)
[ "$DELETE" = true ]  && RSYNC_OPTS+=(--delete)
[ "$PARTIAL" = true ] && RSYNC_OPTS+=(--partial)

# ============================================
# Deploy
# ============================================

echo "=========================================="
echo "Deploying octeth-backup-tools"
echo "  From:   ${SCRIPT_DIR}/"
echo "  To:     ${DEPLOY_USER}@${DEPLOY_HOST}:${DEPLOY_PATH}/ (port ${SSH_PORT})"
echo "  Backup: ${BACKUP_DIR}/ (on server)"
echo "  Mode:   $([ "$DRY_RUN" = true ] && echo 'DRY RUN' || echo 'LIVE')"
echo "  Config: $([ "$INCLUDE_ENV" = true ] && echo 'INCLUDING config/.env + backup.conf' || echo 'excluding live config/.env + backup.conf')"
echo "=========================================="

rsync "${RSYNC_OPTS[@]}" \
    -e "ssh -p ${SSH_PORT}" \
    "${SCRIPT_DIR}/" \
    "${DEPLOY_USER}@${DEPLOY_HOST}:${DEPLOY_PATH}/"

if [ "$DRY_RUN" = true ]; then
    echo ""
    echo "Dry run complete. Re-run without --dry-run to deploy."
    exit 0
fi

# Make sure the scripts are executable on the server
echo ""
echo "Setting executable permissions on server scripts..."
ssh -p "${SSH_PORT}" "${DEPLOY_USER}@${DEPLOY_HOST}" \
    "chmod +x '${DEPLOY_PATH}'/bin/*.sh '${DEPLOY_PATH}'/*.sh 2>/dev/null || true"

echo ""
echo "Deploy complete."
echo "Replaced files (if any) were backed up to: ${BACKUP_DIR}/ on the server."
