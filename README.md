# Octeth MySQL Backup Tool

A professional, production-ready MySQL backup solution for Octeth using Percona XtraBackup. Designed for zero-downtime hot backups of large databases (2GB+) with intelligent retention policies and S3 integration.

## Features

- **Zero-Downtime Hot Backups**: Uses Percona XtraBackup for hot backups while MySQL stays online
- **Smart Retention Policy**: Daily (7 days) + Weekly (4 weeks) + Monthly (6 months)
- **Dual Storage**: Local filesystem + S3-compatible cloud storage
- **Production-Ready**: Comprehensive error handling, logging, and notifications
- **Fast & Efficient**: 70-80% less CPU usage compared to mysqldump
- **Parallel Compression**: Supports pigz for faster compression
- **Easy Restore**: Simple restore process with verification
- **Automated Cleanup**: Automatic retention policy enforcement

## Why XtraBackup?

Traditional `mysqldump` becomes impractical for large databases:
- **mysqldump on 2GB+ database**: Hours of runtime, high CPU load, table locks
- **XtraBackup on 2GB+ database**: 5-15 minutes, minimal CPU, no downtime

XtraBackup copies InnoDB data files directly and uses transaction logs to maintain consistency, making it ideal for production systems.

## Architecture

```
octeth-backup-tools/
├── bin/
│   ├── octeth-backup.sh          # Main backup script
│   ├── octeth-restore.sh         # Restore script
│   └── octeth-cleanup.sh         # Retention policy cleanup
├── config/
│   ├── .env.example              # Environment configuration template
│   └── backup.conf.example       # Backup configuration template
├── install.sh                    # Installation script
└── README.md                     # This file
```

## Quick Start

### 1. Installation

```bash
# Clone or copy this repository
cd octeth-backup-tools

# Run installation (installs dependencies, sets up config, and cron)
sudo ./install.sh

# Or run with wizard for guided setup
sudo ./install.sh --wizard
```

The installer will:
- Check/install Percona XtraBackup 8.0
- Install compression tools (pigz recommended)
- Optionally install AWS CLI for S3 backups
- Create configuration files
- Set up cron jobs for automated backups

### 2. Configuration

Edit `config/.env` with your MySQL credentials:

```bash
# MySQL Connection
MYSQL_HOST=oempro_mysql
MYSQL_ROOT_PASSWORD=your_root_password
MYSQL_DATABASE=oempro

# Backup Storage
BACKUP_DIR=/var/backups/octeth

# S3 Settings (optional)
S3_UPLOAD_ENABLED=true
S3_BUCKET=my-octeth-backups
S3_REGION=us-east-1
AWS_ACCESS_KEY_ID=your_key
AWS_SECRET_ACCESS_KEY=your_secret
```

### 3. First Backup

```bash
# Run your first backup manually
./bin/octeth-backup.sh

# Check backup was created
./bin/octeth-restore.sh --list
```

## Usage

### Backup Operations

```bash
# Manual backup
./bin/octeth-backup.sh

# Backup runs automatically via cron (default: daily at 2 AM)
```

The backup script automatically:
1. Checks disk space and MySQL connectivity
2. Determines backup type (daily/weekly/monthly based on date)
3. Performs hot backup with XtraBackup
4. Compresses and creates checksum
5. Uploads to S3 (if enabled)
6. Sends notifications
7. Logs everything

### Restore Operations

```bash
# List available local backups
./bin/octeth-restore.sh --list

# List S3 backups
./bin/octeth-restore.sh --list-s3

# Restore from local backup
./bin/octeth-restore.sh --file /var/backups/octeth/daily/octeth-backup-2025-01-15_02-00-00.tar.gz

# Restore from S3
./bin/octeth-restore.sh --s3 octeth-backup-2025-01-15_02-00-00.tar.gz daily

# Force restore (skip checksum verification)
./bin/octeth-restore.sh --file backup.tar.gz --force

# Skip confirmation prompt
./bin/octeth-restore.sh --file backup.tar.gz --yes
```

**Warning**: Restore operations will:
1. Stop the MySQL container
2. Backup current data (safety backup)
3. Replace MySQL data with backup
4. Restart MySQL

### Cleanup Operations

```bash
# Show backup statistics
./bin/octeth-cleanup.sh --stats

# Dry run (see what would be deleted)
./bin/octeth-cleanup.sh --dry-run

# Perform cleanup
./bin/octeth-cleanup.sh

# Verbose output
./bin/octeth-cleanup.sh --verbose
```

Cleanup runs automatically after backups (via cron) and enforces the retention policy:
- **Daily**: Keep last 7 backups
- **Weekly**: Keep last 4 Sunday backups
- **Monthly**: Keep last 6 first-of-month backups

## Configuration Reference

### Environment Variables (.env)

#### MySQL Settings
```bash
MYSQL_HOST=oempro_mysql          # MySQL container name
MYSQL_PORT=3306                  # MySQL port
MYSQL_ROOT_PASSWORD=             # Root password (required)
MYSQL_DATABASE=oempro            # Database name
MYSQL_USERNAME=oempro            # MySQL user
MYSQL_PASSWORD=                  # MySQL password
```

#### Backup Storage
```bash
BACKUP_DIR=/var/backups/octeth   # Local backup directory
TEMP_DIR=/tmp/octeth-backup      # Temporary directory
MAX_DISK_USAGE=85                # Maximum disk usage % (abort if exceeded)
MIN_FREE_SPACE_GB=10             # Minimum free space required
```

#### Compression
```bash
COMPRESSION_TOOL=auto            # auto, pigz, or gzip
COMPRESSION_LEVEL=6              # 1-9 (6 recommended)
PARALLEL_THREADS=auto            # auto or number
```

#### S3 Storage
```bash
S3_UPLOAD_ENABLED=false          # Enable S3 uploads
S3_BUCKET=my-octeth-backups      # S3 bucket name
S3_REGION=us-east-1              # S3 region
S3_PREFIX=octeth                 # S3 path prefix
S3_STORAGE_CLASS=STANDARD_IA     # S3 storage class
AWS_ACCESS_KEY_ID=               # AWS credentials
AWS_SECRET_ACCESS_KEY=
S3_UPLOAD_TOOL=awscli            # awscli or rclone
```

#### Retention Policy
```bash
RETENTION_DAILY=7                # Keep last 7 daily backups
RETENTION_WEEKLY=4               # Keep last 4 weekly backups
RETENTION_MONTHLY=6              # Keep last 6 monthly backups
```

#### Notifications
```bash
EMAIL_NOTIFICATIONS=false        # Enable email notifications
EMAIL_TO=admin@example.com       # Recipient emails (comma-separated)
EMAIL_FROM=backup@example.com    # Sender email
SMTP_HOST=smtp.gmail.com         # SMTP server
SMTP_PORT=587                    # SMTP port
SMTP_USERNAME=                   # SMTP username
SMTP_PASSWORD=                   # SMTP password
NOTIFY_ON_FAILURE_ONLY=true      # Only notify on failures

WEBHOOK_ENABLED=false            # Enable webhook notifications
WEBHOOK_URL=                     # Webhook URL
```

#### Advanced Settings
```bash
VERIFY_BACKUP=true               # Verify backup after creation
LOCK_FILE=/tmp/octeth-backup.lock # Lock file path
LOG_FILE=/var/log/octeth-backup.log # Log file path
LOG_RETENTION_DAYS=30            # Keep logs for N days
DOCKER_CMD=docker                # Docker command (use "sudo docker" if needed)
BACKUP_TIMEOUT=120               # Backup timeout in minutes
```

## Backup Types & Retention

The tool automatically determines backup type based on the current date:

| Type | When | Retention | Storage Path |
|------|------|-----------|--------------|
| **Monthly** | 1st of month | 6 months | `/var/backups/octeth/monthly/` |
| **Weekly** | Sunday | 4 weeks | `/var/backups/octeth/weekly/` |
| **Daily** | All other days | 7 days | `/var/backups/octeth/daily/` |

### Example Timeline

If backups run daily at 2 AM:
- **Day 1-6**: Daily backups only
- **Day 7 (Sunday)**: Creates weekly backup (also kept as daily)
- **Day 1 of Month (Sunday)**: Creates monthly backup (also kept as weekly and daily)

Cleanup runs automatically and removes:
- Daily backups older than 7 days
- Weekly backups older than 4 weeks
- Monthly backups older than 6 months

## S3 Storage

### AWS CLI Setup

```bash
# Install AWS CLI (done by install.sh)
# Configure in .env or use IAM instance role

# Test S3 access
aws s3 ls s3://my-octeth-backups/
```

### rclone Setup

```bash
# Install rclone
curl https://rclone.org/install.sh | sudo bash

# Configure rclone
rclone config

# Set in .env
S3_UPLOAD_TOOL=rclone
RCLONE_REMOTE=s3
```

### S3 Storage Classes

Choose based on your recovery time requirements:

- **STANDARD**: Frequent access, highest cost
- **STANDARD_IA** (recommended): Infrequent access, 30-day minimum
- **GLACIER_IR**: Archive, minutes retrieval, lowest cost
- **DEEP_ARCHIVE**: Long-term, 12-hour retrieval

## Monitoring & Notifications

### Email Notifications

Configure SMTP in `.env` to receive email notifications:

```bash
EMAIL_NOTIFICATIONS=true
EMAIL_TO=admin@example.com,backup-team@example.com
SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_USERNAME=your_email@gmail.com
SMTP_PASSWORD=your_app_password
NOTIFY_ON_FAILURE_ONLY=true
```

For Gmail, use an [App Password](https://support.google.com/accounts/answer/185833).

### Webhook Notifications

Send backup status to monitoring systems:

```bash
WEBHOOK_ENABLED=true
WEBHOOK_URL=https://hooks.slack.com/services/YOUR/WEBHOOK/URL
```

Webhook payload:
```json
{
  "status": "success",
  "message": "Octeth backup completed",
  "timestamp": "2025-01-15T02:00:00Z",
  "backup_size": "2.4GB"
}
```

### Log Files

All operations are logged to `/var/log/octeth-backup.log`:

```bash
# View recent logs
tail -f /var/log/octeth-backup.log

# Search for errors
grep ERROR /var/log/octeth-backup.log

# View backup history
grep "Backup completed" /var/log/octeth-backup.log
```

Logs are automatically rotated and cleaned up after 30 days.

## Cron Setup

The installer creates cron jobs automatically:

```cron
# Backup at 2 AM daily
0 2 * * * /path/to/octeth-backup-tools/bin/octeth-backup.sh

# Cleanup at 2:30 AM daily
30 2 * * * /path/to/octeth-backup-tools/bin/octeth-cleanup.sh
```

### Custom Schedule

```bash
# Edit cron
crontab -e

# Examples:
0 2 * * *       # Daily at 2 AM
0 */6 * * *     # Every 6 hours
0 3 * * 0       # Weekly on Sunday at 3 AM
0 1 1 * *       # Monthly on 1st at 1 AM
```

## Performance & Best Practices

### Backup Performance

For a 2GB database:
- **Backup time**: 5-15 minutes
- **CPU usage**: Low (file copy operations)
- **I/O usage**: Moderate (reading data files)
- **Downtime**: Zero

For larger databases:
- 10GB: ~30-45 minutes
- 50GB: 2-3 hours
- 100GB+: 4-6 hours

### Optimization Tips

1. **Use pigz**: Install pigz for 3-4x faster compression
   ```bash
   sudo apt-get install pigz
   ```

2. **Adjust compression level**: Lower = faster, higher = smaller
   ```bash
   COMPRESSION_LEVEL=3  # Fast, larger files
   COMPRESSION_LEVEL=9  # Slow, smaller files
   ```

3. **Tune parallel threads**: Match your CPU cores
   ```bash
   PARALLEL_THREADS=8  # For 8-core CPU
   ```

4. **Run during off-peak hours**: Minimize impact on production
   ```bash
   0 2 * * *  # 2 AM is typical
   ```

5. **Monitor disk space**: Ensure adequate free space
   ```bash
   # Rule of thumb: 2-3x database size
   # For 10GB database, keep 20-30GB free
   ```

### Storage Planning

Calculate required storage:

```
Daily retention:   7 days  × backup_size = 7 × backup_size
Weekly retention:  4 weeks × backup_size = 4 × backup_size
Monthly retention: 6 months × backup_size = 6 × backup_size

Total: ~17 × backup_size
```

Example for 5GB compressed backups:
- Local: ~85GB
- S3: ~85GB (with lifecycle policies)

### Cost Optimization

1. **Use S3 Intelligent-Tiering or Lifecycle Policies**
   ```bash
   # Move old backups to cheaper storage automatically
   # S3 Console → Bucket → Management → Lifecycle rules
   ```

2. **Keep fewer monthly backups locally**
   ```bash
   RETENTION_MONTHLY=3  # Keep only 3 months locally
   # Use S3 for longer-term retention
   ```

3. **Compress more aggressively**
   ```bash
   COMPRESSION_LEVEL=9  # Smaller files, slightly slower
   ```

## Troubleshooting

### Backup Fails: "XtraBackup not found"

```bash
# Install XtraBackup manually
sudo ./install.sh --deps-only

# Or follow manual installation:
# Ubuntu/Debian:
wget https://repo.percona.com/apt/percona-release_latest.$(lsb_release -sc)_all.deb
sudo dpkg -i percona-release_latest.$(lsb_release -sc)_all.deb
sudo apt-get update
sudo percona-release enable-only tools release
sudo apt-get install percona-xtrabackup-80
```

### Backup Fails: "Cannot connect to MySQL"

```bash
# Check MySQL container is running
docker ps | grep mysql

# Check MySQL credentials in .env
docker exec oempro_mysql mysql -uroot -p'your_password' -e "SHOW DATABASES;"

# Check Docker command
# If you need sudo for docker, set in .env:
DOCKER_CMD="sudo docker"
```

### Backup Fails: "Disk space"

```bash
# Check available space
df -h /var/backups

# Clean up old backups manually
./bin/octeth-cleanup.sh

# Or increase MAX_DISK_USAGE in .env
MAX_DISK_USAGE=90
```

### S3 Upload Fails

```bash
# Test AWS CLI access
aws s3 ls s3://your-bucket-name/

# Check credentials in .env
# Verify IAM permissions:
# - s3:PutObject
# - s3:GetObject
# - s3:ListBucket
# - s3:DeleteObject
```

### Restore Fails: "Checksum verification failed"

```bash
# Restore with --force to skip checksum
./bin/octeth-restore.sh --file backup.tar.gz --force

# Or verify backup manually
sha256sum -c backup.tar.gz.sha256
```

### Lock File Issues

```bash
# Remove stale lock file
rm -f /tmp/octeth-backup.lock

# Check for running backup processes
ps aux | grep octeth-backup
```

## Security Considerations

1. **Protect configuration files**
   ```bash
   chmod 600 config/.env
   # Never commit .env to git (it's in .gitignore)
   ```

2. **Use secure S3 access**
   - Prefer IAM instance roles over hardcoded credentials
   - Use least-privilege IAM policies
   - Enable S3 bucket encryption

3. **Restrict file permissions**
   ```bash
   chmod 700 bin/*.sh
   chmod 600 config/.env
   ```

4. **Monitor backup logs**
   ```bash
   # Check for suspicious activity
   grep -i "error\|fail\|warning" /var/log/octeth-backup.log
   ```

5. **Test restores regularly**
   ```bash
   # Verify backups are valid
   # Restore to test environment monthly
   ```

## Integration with Octeth

This tool integrates seamlessly with Octeth:

1. **Automatic MySQL detection**: Connects to `oempro_mysql` container
2. **Respects Docker network**: Uses existing Octeth Docker network
3. **No service disruption**: Zero downtime backups
4. **Compatible with all Octeth versions**: Works with v5.7.1+

You can also integrate with Octeth's CLI:

```bash
# Add to octeth CLI (optional)
cd /path/to/oempro
ln -s /path/to/octeth-backup-tools/bin/octeth-backup.sh cli/backup.sh

# Then run via Octeth CLI
./cli/octeth.sh backup
```

## Testing

### Test Backup

```bash
# Run backup manually
./bin/octeth-backup.sh

# Verify backup exists
./bin/octeth-restore.sh --list

# Check logs
tail -50 /var/log/octeth-backup.log
```

### Test Restore (Non-Production Only!)

```bash
# DANGER: Only test restore in development/staging!
# This will replace your database!

# List backups
./bin/octeth-restore.sh --list

# Restore
./bin/octeth-restore.sh --file /var/backups/octeth/daily/octeth-backup-YYYY-MM-DD.tar.gz --yes
```

### Test Cleanup

```bash
# Dry run to see what would be deleted
./bin/octeth-cleanup.sh --dry-run

# View statistics
./bin/octeth-cleanup.sh --stats
```

## FAQ

### Q: Does this cause downtime?
**A:** No. XtraBackup performs hot backups with zero downtime. MySQL stays online and applications continue running.

### Q: How long does a backup take?
**A:** For a 2GB database: 5-15 minutes. Larger databases scale linearly.

### Q: Can I run backups more frequently?
**A:** Yes. Modify the cron schedule. XtraBackup is efficient enough for hourly backups if needed.

### Q: What happens if backup fails?
**A:** The script logs errors, sends notifications (if configured), and exits without affecting your database.

### Q: Can I restore to a different server?
**A:** Yes. Copy the backup file to the new server and run the restore script.

### Q: How much disk space do I need?
**A:** Plan for ~17x your compressed backup size for local retention (7 daily + 4 weekly + 6 monthly).

### Q: What if I delete a backup by mistake?
**A:** If S3 is enabled, download from S3. Otherwise, backups are gone. Enable S3 for redundancy.

### Q: Can I encrypt backups?
**A:** Currently not built-in. You can add GPG encryption by modifying the backup script or use S3 server-side encryption.

## License

MIT License - See LICENSE file for details

## Support

For issues, questions, or contributions:
- GitHub Issues: [Your Repository URL]
- Documentation: This README
- Octeth Support: support@octeth.com

## Changelog

### v1.0.0 (2025-01-21)
- Initial release
- Percona XtraBackup 8.0 integration
- Zero-downtime hot backups
- Smart retention policy (Daily 7 + Weekly 4 + Monthly 6)
- S3 support (AWS CLI and rclone)
- Email and webhook notifications
- Automated installation and cron setup
- Comprehensive restore functionality
- Production-ready logging and error handling

---

**Made for Octeth** - Professional email marketing platform
