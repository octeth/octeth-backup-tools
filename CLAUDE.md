# CLAUDE.md - Octeth MySQL Backup Tool

This file provides comprehensive guidance for AI assistants (Claude, GitHub Copilot, etc.) working with the Octeth Backup Tools codebase.

## Project Overview

**Octeth MySQL Backup Tool** is a production-ready MySQL backup solution designed for zero-downtime hot backups of large databases (2GB+) using Percona XtraBackup. It integrates seamlessly with Octeth (an email marketing platform) but can be adapted for any MySQL/Docker setup.

### Key Features
- **Zero-Downtime Hot Backups**: Uses Percona XtraBackup for hot backups while MySQL stays online
- **Smart Retention Policy**: Daily (7 days) + Weekly (4 weeks) + Monthly (6 months)
- **Dual Storage**: Local filesystem + S3-compatible cloud storage
- **Production-Ready**: Comprehensive error handling, logging, and notifications
- **Fast & Efficient**: 70-80% less CPU usage compared to mysqldump
- **Parallel Compression**: Supports pigz for faster compression
- **Easy Restore**: Simple restore process with verification
- **Automated Cleanup**: Automatic retention policy enforcement

### Technology Stack
- **Shell**: Bash scripting (POSIX-compatible where possible)
- **Database**: MySQL 8.0+ (via Docker containers)
- **Backup Tool**: Percona XtraBackup 8.0
- **Compression**: pigz (parallel gzip) or gzip
- **Cloud Storage**: AWS S3 (via AWS CLI or rclone)
- **Containerization**: Docker for MySQL
- **Orchestration**: Cron for scheduled backups

## Repository Structure

```
octeth-backup-tools/
├── bin/                          # Executable scripts
│   ├── octeth-backup.sh         # Main backup script (565 lines)
│   ├── octeth-restore.sh        # Restore script (596 lines)
│   └── octeth-cleanup.sh        # Retention policy cleanup (421 lines)
├── config/                       # Configuration templates
│   ├── .env.example             # Environment variables template
│   └── backup.conf.example      # Main configuration template
├── .github/workflows/           # GitHub Actions
│   ├── claude.yml              # Claude Code automation
│   └── claude-code-review.yml  # Automatic PR reviews
├── install.sh                   # Installation script (537 lines)
├── README.md                    # User documentation (806 lines)
└── CLAUDE.md                    # This file (AI assistant guidance)
```

## Core Components

### 1. Backup Script (`bin/octeth-backup.sh`)

**Purpose**: Performs hot backups of MySQL databases using XtraBackup.

**Key Functions**:
- `check_lock_file()`: Prevents concurrent backup runs (lines 95-110)
- `check_xtrabackup()`: Verifies XtraBackup installation (lines 112-121)
- `check_disk_space()`: Validates sufficient disk space, critical for avoiding "No space left on device" errors (lines 123-167)
- `check_mysql_connection()`: Tests MySQL connectivity (lines 169-178)
- `determine_backup_type()`: Determines daily/weekly/monthly based on date (lines 201-221)
- `perform_backup()`: Executes XtraBackup hot backup (lines 227-307)
- `compress_backup()`: Compresses backup with pigz/gzip (lines 309-338)
- `upload_to_s3()`: Uploads to S3 storage (lines 344-373)
- `send_notifications()`: Sends email/webhook notifications (lines 421-488)

**Critical Implementation Details**:
- Uses XtraBackup from the HOST, not inside the container (line 277)
- Requires access to MySQL data directory on host filesystem (MYSQL_DATA_DIR)
- Calculates required temp space: DB size + 20% + 5GB buffer (lines 150-164)
- Creates checksums (SHA256) for all backups (lines 328-330)
- Supports both direct port access and container IP connection (lines 243-261)

**Error Handling**:
- Comprehensive disk space checks before backup starts
- Lock file mechanism to prevent concurrent runs
- Transaction log cleanup on failure
- Detailed error logging with timestamps

### 2. Restore Script (`bin/octeth-restore.sh`)

**Purpose**: Restores MySQL databases from XtraBackup backups.

**Key Functions**:
- `list_local_backups()`: Lists available local backups with metadata (lines 96-147)
- `list_s3_backups()`: Lists S3 backups (lines 149-166)
- `download_from_s3()`: Downloads backup from S3 (lines 214-230)
- `verify_checksum()`: Verifies backup integrity (lines 284-306)
- `perform_restore()`: Executes full restore process (lines 312-466)

**Critical Implementation Details**:
- **macOS/POSIX Compatibility**: Uses helper functions for cross-platform compatibility (lines 39-62)
- Stops MySQL container before restore (line 369)
- Creates safety backup of current data (lines 377-402)
- Clears and replaces MySQL data directory (lines 404-417)
- Fixes permissions (999:999 for MySQL container) (line 421)
- Waits for MySQL to become ready after restart (lines 433-449)

**Safety Features**:
- Checksum verification before restore (with --force override)
- User confirmation prompt (with --yes skip option)
- Safety backup of current database before restoration
- Detailed restore verification with table count

### 3. Cleanup Script (`bin/octeth-cleanup.sh`)

**Purpose**: Enforces retention policies for local and S3 backups.

**Key Functions**:
- `cleanup_directory()`: Removes old backups based on retention count (lines 86-136)
- `cleanup_s3_backups()`: Cleans up S3 backups (lines 138-154)
- `cleanup_s3_with_aws_cli()`: AWS CLI implementation (lines 156-215)
- `cleanup_s3_with_rclone()`: rclone implementation (lines 217-266)
- `cleanup_old_logs()`: Removes old log files (lines 268-291)
- `show_statistics()`: Displays backup statistics (lines 297-321)

**Retention Policy**:
- Daily backups: Keep last 7 (configurable via RETENTION_DAILY)
- Weekly backups: Keep last 4 Sundays (configurable via RETENTION_WEEKLY)
- Monthly backups: Keep last 6 first-of-month (configurable via RETENTION_MONTHLY)

**Features**:
- Dry-run mode for testing (`--dry-run`)
- Verbose logging (`--verbose`)
- Statistics-only mode (`--stats`)
- Automatic checksum file cleanup

### 4. Installation Script (`install.sh`)

**Purpose**: Automates installation and setup of dependencies.

**Key Functions**:
- `detect_os()`: Detects Linux distribution (lines 46-57)
- `detect_package_manager()`: Identifies apt/yum/dnf (lines 59-69)
- `check_docker()`: Verifies Docker installation (lines 75-87)
- `install_xtrabackup()`: Installs Percona XtraBackup 8.0 (lines 102-148)
- `install_pigz()`: Installs pigz for parallel compression (lines 176-198)
- `install_aws_cli()`: Installs AWS CLI for S3 (lines 213-242)
- `setup_configuration()`: Creates config files from templates (lines 261-298)
- `setup_cron()`: Configures cron jobs for automation (lines 304-346)
- `run_config_wizard()`: Interactive configuration wizard (lines 352-395)

**Supported Platforms**:
- Ubuntu/Debian (apt)
- CentOS/RHEL/Rocky/AlmaLinux (yum)
- Fedora (dnf)

## Configuration System

### Environment Variables (`.env`)

Configuration is split into two files:
1. **config/.env**: Environment-specific settings (credentials, paths)
2. **config/backup.conf**: Script configuration (sourced by all scripts)

**Critical Variables**:

```bash
# MySQL Connection
MYSQL_HOST=oempro_mysql              # Container name
MYSQL_ROOT_PASSWORD=                 # Required for XtraBackup
MYSQL_DATA_DIR=                      # HOST path to MySQL data (CRITICAL)

# Storage
BACKUP_DIR=/var/backups/octeth       # Local backup location
TEMP_DIR=/var/backups/octeth/tmp     # Must have DB size + 20% + 5GB free

# Compression
COMPRESSION_TOOL=auto                # auto, pigz, or gzip
COMPRESSION_LEVEL=6                  # 1-9 balance

# S3 Storage
S3_UPLOAD_ENABLED=false
S3_BUCKET=
S3_REGION=us-east-1
S3_STORAGE_CLASS=STANDARD_IA
AWS_ACCESS_KEY_ID=
AWS_SECRET_ACCESS_KEY=

# Retention
RETENTION_DAILY=7
RETENTION_WEEKLY=4
RETENTION_MONTHLY=6

# Notifications
EMAIL_NOTIFICATIONS=false
WEBHOOK_ENABLED=false

# Advanced
DOCKER_CMD=docker                    # Use "sudo docker" if needed
VERIFY_BACKUP=true                   # Runs XtraBackup --prepare
```

### Backup Configuration (`backup.conf`)

Loads `.env` and defines:
- Backup naming conventions (octeth-backup-YYYY-MM-DD_HH-MM-SS)
- Directory structure (daily/, weekly/, monthly/)
- Command templates for Docker, MySQL, XtraBackup
- Retention policy details (WEEKLY_DAY=0 for Sunday, MONTHLY_DAY=1)
- Notification templates

## Development Guidelines

### Coding Standards

1. **Shell Scripting**:
   - Use `set -euo pipefail` for strict error handling
   - Quote all variables: `"${VARIABLE}"`
   - Use `$(command)` instead of backticks
   - Prefer `[[` over `[` for conditionals
   - Use `local` for function variables

2. **POSIX Compatibility**:
   - Bash 3.x compatible (macOS compatibility)
   - Use helper functions for case conversion (lines 39-50 in restore/cleanup)
   - Platform-specific `stat` commands (lines 54-62 in restore)
   - Avoid Bash 4+ features (associative arrays, etc.)

3. **Error Handling**:
   - Check exit codes of critical operations
   - Use `|| { log_error "message"; exit 1; }` pattern
   - Cleanup temp files in trap handlers
   - Log all errors with timestamps

4. **Logging**:
   - Use logging functions: `log_info`, `log_error`, `log_warn`, `log_success`
   - Include timestamps: `[YYYY-MM-DD HH:MM:SS] [LEVEL] message`
   - Log to both stdout and log file: `tee -a "${LOG_FILE}"`
   - Include context in error messages

5. **Security**:
   - Never log passwords
   - Use `chmod 600` for config files
   - Validate user input
   - Sanitize file paths
   - Use `--` to prevent argument injection

### Testing Approach

**Manual Testing Checklist**:
1. Fresh installation on clean system
2. Backup creation (daily/weekly/monthly)
3. Checksum verification
4. S3 upload/download
5. Restore process (with and without force)
6. Cleanup with dry-run
7. Edge cases:
   - Insufficient disk space
   - Missing dependencies
   - Invalid credentials
   - Network failures
   - Corrupted backups

**Test Environments**:
- Ubuntu 20.04/22.04 LTS
- CentOS/RHEL 8/9
- macOS (for restore script POSIX compatibility)

### Common Pitfalls

1. **Disk Space Issues**:
   - TEMP_DIR often set to `/tmp` which is too small
   - Must calculate: DB size + 20% buffer + 5GB
   - Solution: Use TEMP_DIR on same disk as BACKUP_DIR

2. **MySQL Data Directory**:
   - Must be HOST path, not container path
   - For Octeth: `/opt/oempro/_dockerfiles/mysql/data_v8`
   - XtraBackup runs from host, reads data files directly

3. **Docker Permissions**:
   - If user needs sudo for docker: `DOCKER_CMD="sudo docker"`
   - Restored data needs 999:999 permissions (MySQL container UID/GID)

4. **macOS Restore Issues**:
   - `lower_case_table_names` mismatch between Linux (0) and macOS (2)
   - Solution: Use Docker named volumes, not bind mounts
   - See README.md lines 661-751 for detailed instructions

5. **S3 Upload Failures**:
   - Check IAM permissions: s3:PutObject, s3:GetObject, s3:ListBucket, s3:DeleteObject
   - Verify credentials are exported correctly
   - Test with `aws s3 ls s3://bucket-name/`

## XtraBackup Technical Details

### Why XtraBackup?

Traditional `mysqldump`:
- 2GB database: Hours of runtime, high CPU, table locks
- Logical backup (SQL statements)
- Single-threaded

Percona XtraBackup:
- 2GB database: 5-15 minutes, minimal CPU, no downtime
- Physical backup (copies data files)
- Multi-threaded
- Hot backup with transaction log consistency

### Backup Process

1. **Backup Phase** (lines 277-291 in octeth-backup.sh):
   ```bash
   xtrabackup --backup \
     --target-dir="${temp_backup_dir}" \
     --datadir="${MYSQL_DATA_DIR}" \
     --host="${mysql_host}" \
     --port="${mysql_port}" \
     --user=root \
     --password="${MYSQL_ROOT_PASSWORD}" \
     --parallel=${threads}
   ```
   - Copies InnoDB data files
   - Records transaction log position
   - No table locks (hot backup)

2. **Prepare Phase** (lines 294-304):
   ```bash
   xtrabackup --prepare --target-dir="${temp_backup_dir}"
   ```
   - Applies transaction logs
   - Makes backup consistent
   - Required for restore

3. **Compression** (lines 320):
   ```bash
   tar -cf - -C "${parent_dir}" "${backup_dirname}" | ${COMPRESSION_TOOL} -${COMPRESSION_LEVEL} > "${dest_file}"
   ```
   - Parallel compression with pigz (3-4x faster)
   - Adjustable compression level (1-9)

### Restore Process

1. **Extract** (line 352 in octeth-restore.sh)
2. **Stop MySQL** (line 369)
3. **Safety Backup** (line 400)
4. **Clear Data Directory** (line 406)
5. **Copy Restored Data** (line 411)
6. **Fix Permissions** (line 421)
7. **Start MySQL** (line 425)
8. **Verify** (lines 452-454)

## Integration with Octeth

### Octeth Context

Octeth is a professional email marketing platform that uses:
- MySQL 8.0 in Docker container (`oempro_mysql`)
- Data directory: `/opt/oempro/_dockerfiles/mysql/data_v8`
- Database: `oempro`
- Typical size: 2GB+ (grows with campaigns and subscribers)

### Docker Network

Backup scripts detect MySQL connection method:
1. Try exposed port: `docker port oempro_mysql 3306`
2. Fallback to container IP: `docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' oempro_mysql`

### Octeth CLI Integration (Optional)

```bash
cd /path/to/oempro
ln -s /path/to/octeth-backup-tools/bin/octeth-backup.sh cli/backup.sh
./cli/octeth.sh backup
```

## GitHub Actions Integration

### Claude Code Workflow (`.github/workflows/claude.yml`)

Triggers on:
- Issue comments containing `@claude`
- PR review comments containing `@claude`
- Issues opened/assigned with `@claude` in title/body

Features:
- Automatic code changes
- PR creation
- Issue management
- CI integration

### Claude Code Review Workflow (`.github/workflows/claude-code-review.yml`)

Triggers on PR open/synchronize.

Reviews:
- Code quality and best practices
- Potential bugs
- Performance considerations
- Security concerns
- Test coverage

Uses `gh pr comment` to post review.

## AI Assistant Guidelines

### When Modifying Code

1. **Read Before Writing**:
   - Always read existing code before suggesting modifications
   - Understand the full context of functions
   - Check for dependencies and side effects

2. **Maintain Compatibility**:
   - Preserve Bash 3.x compatibility for macOS
   - Keep POSIX-compatible where possible
   - Test on multiple platforms if changing core logic

3. **Error Handling**:
   - Add appropriate error checks
   - Include descriptive error messages
   - Log errors to both stdout and log file
   - Consider cleanup in failure scenarios

4. **Documentation**:
   - Update README.md for user-facing changes
   - Update CLAUDE.md for architectural changes
   - Add inline comments for complex logic
   - Update configuration examples

5. **Security**:
   - Never log sensitive data (passwords, keys)
   - Validate and sanitize inputs
   - Use proper file permissions
   - Avoid command injection vulnerabilities

### Common Tasks

#### Adding a New Backup Feature

1. Add configuration to `config/.env.example`
2. Implement in `bin/octeth-backup.sh`
3. Add logging at INFO level
4. Update error handling
5. Update README.md usage section
6. Test manually with various scenarios

#### Adding a New Restore Feature

1. Add option to `usage()` function
2. Add argument parsing in `main()`
3. Implement feature function
4. Add to restore workflow
5. Update README.md examples
6. Test with actual backups

#### Improving Error Messages

1. Locate error in logging
2. Add context (what was being attempted)
3. Suggest solution or next steps
4. Include relevant variables (sanitized)
5. Update troubleshooting section in README.md

### Code Review Checklist

When reviewing PRs:
- [ ] Bash syntax errors (use `shellcheck`)
- [ ] Error handling for all critical operations
- [ ] Proper variable quoting
- [ ] Security concerns (command injection, password exposure)
- [ ] POSIX compatibility (avoid Bash 4+ features)
- [ ] Logging consistency (level, format, content)
- [ ] Documentation updates
- [ ] Configuration examples updated
- [ ] Backward compatibility
- [ ] Edge case handling

## Performance Considerations

### Backup Performance

Typical performance for 2GB database:
- Backup time: 5-15 minutes
- Compression: 50-70% size reduction
- CPU usage: Low (file I/O bound)
- Network (S3): Depends on bandwidth

Optimization tips:
1. Use pigz for parallel compression (3-4x faster)
2. Adjust compression level (lower = faster)
3. Run during off-peak hours
4. Ensure fast disk I/O for temp directory

### Storage Planning

Formula: `Total = RETENTION_DAILY × backup_size + RETENTION_WEEKLY × backup_size + RETENTION_MONTHLY × backup_size`

Default (7 daily + 4 weekly + 6 monthly) = ~17 × backup_size

Example for 5GB compressed backups:
- Local: ~85GB
- S3: ~85GB

Cost optimization:
- Use S3 lifecycle policies (move to Glacier after 30 days)
- Reduce local retention, keep longer retention in S3
- Increase compression level (trade CPU for storage)

## Troubleshooting Guide

### "No space left on device"

**Cause**: TEMP_DIR too small for uncompressed database.

**Solution**:
1. Set `TEMP_DIR=/var/backups/octeth/tmp` in .env
2. Ensure disk has DB size + 20% + 5GB free
3. Clean up old backups: `./bin/octeth-cleanup.sh`

### "XtraBackup not found"

**Cause**: Percona XtraBackup not installed.

**Solution**:
```bash
sudo ./install.sh --deps-only
```

### "Cannot connect to MySQL"

**Cause**: Container not running or wrong credentials.

**Solution**:
1. Check container: `docker ps | grep mysql`
2. Test connection: `docker exec oempro_mysql mysql -uroot -p'password' -e "SHOW DATABASES;"`
3. Verify MYSQL_HOST and MYSQL_ROOT_PASSWORD in .env

### "Checksum verification failed"

**Cause**: Backup corrupted during transfer or storage.

**Solution**:
1. Try restore with `--force` (if acceptable risk)
2. Download from S3 again
3. Use a different backup
4. Check disk health

### macOS Restore Issues

**Cause**: `lower_case_table_names` mismatch (Linux=0, macOS=2).

**Solution**: Use Docker named volumes instead of bind mounts (see README.md lines 661-751).

## Security Best Practices

1. **Configuration Files**:
   ```bash
   chmod 600 config/.env
   chmod 700 bin/*.sh
   ```

2. **S3 Access**:
   - Prefer IAM instance roles over hardcoded credentials
   - Use least-privilege IAM policies
   - Enable S3 bucket encryption (AES-256 or KMS)

3. **Backup Encryption** (future enhancement):
   - Add GPG encryption option
   - Store keys securely (not in config files)
   - Document key management process

4. **Monitoring**:
   - Enable notifications for backup failures
   - Monitor disk space regularly
   - Review logs for suspicious activity
   - Test restores regularly (monthly recommended)

5. **Access Control**:
   - Limit access to backup server
   - Use separate credentials for backups (principle of least privilege)
   - Audit backup access logs

## Future Enhancements

Potential improvements (not yet implemented):

1. **Backup Encryption**: GPG encryption for backups at rest
2. **Incremental Backups**: Use XtraBackup incremental feature
3. **Backup Validation**: Automated restore testing
4. **Multi-Database**: Support multiple databases in single run
5. **Monitoring Dashboard**: Web UI for backup status
6. **Prometheus Metrics**: Export backup metrics
7. **Disaster Recovery**: Automated failover procedures
8. **Backup Catalog**: Database of all backups with metadata
9. **Compression Options**: zstd support for better compression
10. **Cloud Providers**: Azure Blob, Google Cloud Storage support

## Contributing

When contributing to this project:

1. **Follow the coding standards** outlined in this document
2. **Test thoroughly** on Ubuntu/Debian before submitting
3. **Update documentation** (README.md and CLAUDE.md)
4. **Add configuration examples** if adding new features
5. **Consider backward compatibility** with existing installations
6. **Use meaningful commit messages** following conventional commits
7. **Request review** from maintainers before merging

## References

- [Percona XtraBackup Documentation](https://www.percona.com/doc/percona-xtrabackup/8.0/)
- [MySQL 8.0 Reference Manual](https://dev.mysql.com/doc/refman/8.0/en/)
- [Bash Reference Manual](https://www.gnu.org/software/bash/manual/)
- [Docker Documentation](https://docs.docker.com/)
- [AWS S3 Documentation](https://docs.aws.amazon.com/s3/)
- [rclone Documentation](https://rclone.org/docs/)

## Support

For issues, questions, or contributions:
- **GitHub Issues**: [Repository Issues](https://github.com/octeth/octeth-backup-tools/issues)
- **Documentation**: See README.md for user guide
- **Octeth Support**: support@octeth.com

---

**Last Updated**: 2025-12-12
**Version**: 1.0.0
**Maintainer**: Octeth Team
