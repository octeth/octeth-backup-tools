# Octeth MySQL Backup Tool

A professional, production-ready MySQL backup solution for Octeth using Percona XtraBackup. Designed for zero-downtime hot backups of large databases (2GB+) with intelligent retention policies and cloud storage integration (AWS S3, Google Cloud Storage, and Cloudflare R2).

## Features

- **Zero-Downtime Hot Backups**: Uses Percona XtraBackup for hot backups while MySQL stays online
- **Smart Retention Policy**: Daily (7 days) + Weekly (4 weeks) + Monthly (6 months)
- **Cloud Storage**: Local filesystem + AWS S3, Google Cloud Storage, or Cloudflare R2
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
│   ├── octeth-cleanup.sh         # Retention policy cleanup
│   └── octeth-test-storage.sh    # Cloud storage connectivity test
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

# MySQL data directory on HOST (required for XtraBackup)
# For Octeth Docker: /opt/oempro/_dockerfiles/mysql/data_v8
MYSQL_DATA_DIR=/opt/oempro/_dockerfiles/mysql/data_v8

# Backup Storage
BACKUP_DIR=/var/backups/octeth

# Cloud Storage (optional - choose s3, gcs, r2, or none)
CLOUD_STORAGE_PROVIDER=s3

# S3 Settings (if using AWS S3)
S3_BUCKET=my-octeth-backups
S3_REGION=us-east-1
AWS_ACCESS_KEY_ID=your_key
AWS_SECRET_ACCESS_KEY=your_secret

# GCS Settings (if using Google Cloud Storage)
# GCS_BUCKET=my-octeth-backups
# GCS_PROJECT_ID=my-project-id
# GOOGLE_APPLICATION_CREDENTIALS=/path/to/credentials.json

# R2 Settings (if using Cloudflare R2)
# R2_BUCKET=my-octeth-backups
# R2_ACCOUNT_ID=your-account-id
# R2_ACCESS_KEY_ID=your_key
# R2_SECRET_ACCESS_KEY=your_secret
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
5. Uploads to cloud storage (if enabled)
6. Sends notifications
7. Logs everything

### Restore Operations

```bash
# List available local backups
./bin/octeth-restore.sh --list

# List cloud backups (S3, GCS, or R2 based on config)
./bin/octeth-restore.sh --list-cloud

# Restore from local backup
./bin/octeth-restore.sh --file /var/backups/octeth/daily/octeth-backup-2025-01-15_02-00-00.tar.gz

# Restore from cloud (uses CLOUD_STORAGE_PROVIDER from config)
./bin/octeth-restore.sh --cloud octeth-backup-2025-01-15_02-00-00.tar.gz daily

# Restore from S3 (specific)
./bin/octeth-restore.sh --s3 octeth-backup-2025-01-15_02-00-00.tar.gz daily

# Restore from GCS (specific)
./bin/octeth-restore.sh --gcs octeth-backup-2025-01-15_02-00-00.tar.gz daily

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
MYSQL_DATA_DIR=                  # MySQL data directory on HOST (required)
                                 # For Octeth: /opt/oempro/_dockerfiles/mysql/data_v8
```

#### Backup Storage
```bash
BACKUP_DIR=/var/backups/octeth      # Local backup directory
TEMP_DIR=/var/backups/octeth/tmp    # Temporary directory (CRITICAL: needs DB size + 20% free space)
                                     # WARNING: Do NOT use /tmp - often too small!
MAX_DISK_USAGE=85                   # Maximum disk usage % (abort if exceeded)
MIN_FREE_SPACE_GB=10                # Minimum free space required
```

**IMPORTANT:** `TEMP_DIR` must have enough space for the full uncompressed database backup. The script calculates required space as: Database Size + 20% buffer + 5GB. Using `/tmp` will likely cause "No space left on device" errors for databases larger than a few GB.

#### Compression
```bash
COMPRESSION_TOOL=auto            # auto, pigz, or gzip
COMPRESSION_LEVEL=6              # 1-9 (6 recommended)
PARALLEL_THREADS=auto            # auto or number
```

#### Cloud Storage
```bash
CLOUD_STORAGE_PROVIDER=none      # s3, gcs, r2, or none
```

#### S3 Storage (AWS/DigitalOcean/MinIO)
```bash
S3_BUCKET=my-octeth-backups      # S3 bucket name
S3_REGION=us-east-1              # S3 region
S3_PREFIX=octeth                 # S3 path prefix
S3_STORAGE_CLASS=STANDARD_IA     # S3 storage class
AWS_ACCESS_KEY_ID=               # AWS credentials (leave empty for IAM role)
AWS_SECRET_ACCESS_KEY=
S3_UPLOAD_TOOL=awscli            # awscli or rclone
RCLONE_REMOTE=s3                 # rclone remote name (if using rclone)
```

#### Google Cloud Storage (GCS)
```bash
GCS_BUCKET=my-octeth-backups     # GCS bucket name
GCS_PROJECT_ID=                  # GCS project ID (optional, auto-detected if not set)
GCS_PREFIX=octeth                # GCS path prefix
GCS_STORAGE_CLASS=NEARLINE       # STANDARD, NEARLINE, COLDLINE, ARCHIVE
GCS_UPLOAD_TOOL=gsutil           # gsutil or rclone
GCS_RCLONE_REMOTE=gcs            # rclone remote name (if using rclone)
GOOGLE_APPLICATION_CREDENTIALS=  # Path to credentials JSON (optional)
```

#### Cloudflare R2 Storage
```bash
R2_BUCKET=my-octeth-backups      # R2 bucket name
R2_ACCOUNT_ID=                   # R2 account ID (required, from Cloudflare dashboard)
R2_PREFIX=octeth                 # R2 path prefix
R2_STORAGE_CLASS=STANDARD        # Not applicable for R2, included for consistency
R2_ACCESS_KEY_ID=                # R2 API token credentials
R2_SECRET_ACCESS_KEY=
R2_UPLOAD_TOOL=awscli            # awscli or rclone
R2_RCLONE_REMOTE=r2              # rclone remote name (if using rclone)
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

## Cloud Storage

### AWS S3 Storage

#### AWS CLI Setup

```bash
# Install AWS CLI (done by install.sh)
# Configure in .env or use IAM instance role

# Configure in .env
CLOUD_STORAGE_PROVIDER=s3
S3_BUCKET=my-octeth-backups
S3_REGION=us-east-1
AWS_ACCESS_KEY_ID=your_key
AWS_SECRET_ACCESS_KEY=your_secret

# Test S3 access
aws s3 ls s3://my-octeth-backups/
```

#### S3 Storage Classes

Choose based on your recovery time requirements:

- **STANDARD**: Frequent access, highest cost
- **STANDARD_IA** (recommended): Infrequent access, 30-day minimum
- **GLACIER_IR**: Archive, minutes retrieval, lowest cost
- **DEEP_ARCHIVE**: Long-term, 12-hour retrieval

### Google Cloud Storage (GCS)

#### gsutil Setup

```bash
# Install Google Cloud SDK
# Ubuntu/Debian:
curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
echo "deb https://packages.cloud.google.com/apt cloud-sdk main" | sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list
sudo apt-get update && sudo apt-get install google-cloud-sdk

# Authenticate
gcloud auth login
gcloud config set project YOUR_PROJECT_ID

# Configure in .env
CLOUD_STORAGE_PROVIDER=gcs
GCS_BUCKET=my-octeth-backups
GCS_PROJECT_ID=my-project-id
GCS_UPLOAD_TOOL=gsutil

# Test GCS access
gsutil ls gs://my-octeth-backups/
```

#### Service Account Setup (Recommended for Production)

```bash
# Create service account in GCP Console
# Download JSON key file

# Configure in .env
GOOGLE_APPLICATION_CREDENTIALS=/path/to/service-account-key.json

# Grant permissions to service account:
# - Storage Object Admin (for bucket)
# - Storage Legacy Bucket Reader (for listing)
```

#### GCS Storage Classes

Choose based on your access patterns and cost requirements:

- **STANDARD**: Frequent access, highest performance
- **NEARLINE** (recommended): Access < 1/month, 30-day minimum
- **COLDLINE**: Access < 1/quarter, 90-day minimum
- **ARCHIVE**: Long-term, 365-day minimum, lowest cost

### Cloudflare R2 Storage

Cloudflare R2 is an S3-compatible object storage with zero egress fees, making it ideal for backups.

#### AWS CLI Setup (R2 via S3 API)

```bash
# Install AWS CLI (done by install.sh)
# R2 uses S3-compatible API with custom endpoint

# Configure in .env
CLOUD_STORAGE_PROVIDER=r2
R2_BUCKET=my-octeth-backups
R2_ACCOUNT_ID=your-account-id  # Found in Cloudflare dashboard
R2_ACCESS_KEY_ID=your_r2_key
R2_SECRET_ACCESS_KEY=your_r2_secret
R2_UPLOAD_TOOL=awscli

# Test R2 access
aws s3 ls s3://my-octeth-backups/ --endpoint-url https://YOUR_ACCOUNT_ID.r2.cloudflarestorage.com
```

#### Getting R2 Credentials

1. Log in to Cloudflare Dashboard
2. Go to R2 > Overview
3. Create a new R2 bucket (if needed)
4. Go to "Manage R2 API Tokens"
5. Create API token with:
   - **Permissions**: Object Read & Write
   - **Bucket**: Specify your backup bucket or all buckets
6. Copy the Access Key ID and Secret Access Key
7. Note your Account ID from the R2 Overview page

#### R2 Features

- **Zero Egress Fees**: No charges for data retrieval
- **S3-Compatible**: Works with AWS CLI and tools
- **Global Performance**: Automatic geographic distribution
- **Cost-Effective**: ~$0.015/GB/month storage

#### rclone Setup for R2

```bash
# Configure rclone for R2
rclone config
# Choose: Amazon S3 or S3-compatible
# Provider: Any S3-compatible
# Endpoint: https://YOUR_ACCOUNT_ID.r2.cloudflarestorage.com
# Enter Access Key ID and Secret Access Key

# Configure in .env
R2_UPLOAD_TOOL=rclone
R2_RCLONE_REMOTE=r2  # Name you gave in rclone config

# Test access
rclone ls r2:my-octeth-backups/
```

### rclone Setup (Works with S3, GCS, and R2)

```bash
# Install rclone
curl https://rclone.org/install.sh | sudo bash

# Configure rclone for S3
rclone config
# Choose: Amazon S3 or S3-compatible

# Configure rclone for GCS
rclone config
# Choose: Google Cloud Storage

# Set in .env
# For S3:
CLOUD_STORAGE_PROVIDER=s3
S3_UPLOAD_TOOL=rclone
RCLONE_REMOTE=s3

# For GCS:
CLOUD_STORAGE_PROVIDER=gcs
GCS_UPLOAD_TOOL=rclone
GCS_RCLONE_REMOTE=gcs
```

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

### Backup Fails: "No space left on device"

This is a critical error that occurs when XtraBackup runs out of disk space during backup. This can also cause MySQL to crash or become unresponsive.

**Symptoms:**
```
xtrabackup: Error writing file ... (OS errno 28 - No space left on device)
```

**Cause:** The `TEMP_DIR` (default: `/tmp/octeth-backup`) doesn't have enough space for the uncompressed database backup.

**Solution:**

1. **Change TEMP_DIR location** (recommended):
   ```bash
   # Edit config/.env
   TEMP_DIR=/var/backups/octeth/tmp  # Use same disk as backups
   ```

2. **Check space requirements:**
   ```bash
   # Check database size
   du -sh /opt/oempro/_dockerfiles/mysql/data_v8

   # Check available space in temp directory
   df -h /var/backups

   # Rule: TEMP_DIR needs DB size + 20% + 5GB free
   # Example: 10GB database needs ~17GB free in TEMP_DIR
   ```

3. **Clean up temp directory:**
   ```bash
   # Remove any stale temp files
   rm -rf /var/backups/octeth/tmp/*
   ```

4. **If MySQL crashed during backup:**
   ```bash
   # Restart MySQL container
   docker restart oempro_mysql

   # Verify MySQL is healthy
   docker logs oempro_mysql
   docker exec oempro_mysql mysql -uroot -p'password' -e "SHOW STATUS LIKE 'Uptime';"
   ```

**Prevention:** Always ensure TEMP_DIR has sufficient space before running backups. The script now checks this automatically and will abort with a clear error if space is insufficient.

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

### Test Cloud Storage Connectivity

The `octeth-test-storage.sh` tool tests connectivity to your configured cloud storage provider (AWS S3, Google Cloud Storage, or Cloudflare R2). It verifies credentials, bucket access, and read/write/delete permissions.

```bash
# Test configured cloud storage
./bin/octeth-test-storage.sh

# Verbose output (detailed logging)
./bin/octeth-test-storage.sh -v

# Quiet mode (for scripting)
./bin/octeth-test-storage.sh -q && echo "Storage ready"
```

**What it tests:**
- ✓ Upload tool installation (AWS CLI, gsutil, or rclone)
- ✓ Authentication and credentials
- ✓ Bucket exists and is accessible
- ✓ Write permissions (uploads test file)
- ✓ Read permissions (downloads test file)
- ✓ Delete permissions (removes test file)
- ✓ Storage class validity

**Example output:**
```
========================================
Octeth Storage Connectivity Test
========================================
Testing cloud storage provider: s3

[✓] AWS CLI found: aws-cli/2.15.30
[✓] AWS credentials configured
[✓] Bucket accessible: s3://my-octeth-backups/octeth/
[✓] Write test passed (uploaded 245 bytes)
[✓] Read test passed (downloaded 245 bytes)
[✓] Delete test passed
[✓] Storage class valid: STANDARD_IA

========================================
All tests passed! ✓
========================================
```

**Exit codes:**
- `0`: All tests passed
- `1`: One or more tests failed
- `2`: Configuration error (missing .env or invalid provider)
- `3`: Tool not installed (aws/gsutil/rclone)

**Use cases:**
- After initial setup to verify cloud configuration
- Before running first backup to catch credential issues
- In automated monitoring (cron job every 6 hours)
- During troubleshooting of backup failures

## Restoring Production Backups to macOS (Local Development)

When restoring XtraBackup backups from a Linux production server to macOS for local development, you'll encounter a `lower_case_table_names` incompatibility:

```
Different lower_case_table_names settings for server ('2') and data dictionary ('0').
Data Dictionary initialization failed.
```

**Why this happens:** Linux uses case-sensitive filesystems (`lower_case_table_names=0`), while macOS uses case-insensitive filesystems (`lower_case_table_names=2`). MySQL stores this setting in the data dictionary and refuses to start if there's a mismatch.

### Solution: Use Docker Named Volumes

Docker named volumes use a Linux filesystem inside Docker Desktop's VM, preserving Linux behavior.

#### Step 1: Create docker-compose.override.yml

Create a file in your Oempro project directory that overrides the MySQL volume:

```yaml
# docker-compose.override.yml (Mac-only, add to .gitignore)
services:
  mysql:
    volumes:
      - ./_dockerfiles/mysql/log_v8:/var/log/mysql
      - ./_dockerfiles/mysql/conf.d:/etc/mysql/conf.d
      - oempro_mysql_data:/var/lib/mysql  # Named volume instead of bind mount

volumes:
  oempro_mysql_data:
```

Add to `.gitignore`:
```bash
echo "docker-compose.override.yml" >> .gitignore
```

#### Step 2: Restore Backup into Docker Volume

```bash
# Download backup from production server to ~/tmp/
scp user@production:/var/backups/octeth/daily/octeth-backup-YYYY-MM-DD.tar.gz ~/tmp/

# Stop and remove all containers that reference the volume
docker compose down

# Delete the previously created volume if it exists
# NOTE: This will fail silently if containers still reference it.
# Always run 'docker compose down' first to remove all containers.
docker volume rm oempro_mysql_data
docker volume rm oempro_oempro_mysql_data

# Verify the volume was actually removed
docker volume inspect oempro_mysql_data
docker volume inspect oempro_oempro_mysql_data

# Extract backup into the Docker volume
docker compose run --rm \
  -v ~/tmp:/backup \
  --entrypoint bash mysql -c \
  "cd /var/lib/mysql && tar -xzf /backup/octeth-backup-YYYY-MM-DD.tar.gz --strip-components=1"
```

#### Step 3: Clean Up XtraBackup Artifacts

```bash
docker compose run --rm --entrypoint bash mysql -c \
  "rm -f /var/lib/mysql/xtrabackup_* /var/lib/mysql/backup-my.cnf /var/lib/mysql/mysql.sock && \
   chown -R mysql:mysql /var/lib/mysql"
```

#### Step 4: Start MySQL

```bash
docker compose up -d mysql

# Verify it's running
docker compose ps mysql
```

#### Important Notes

- **Use production passwords**: The restored database has production MySQL credentials, not your local `.env` passwords
- **Volume persists**: The named volume persists between container restarts. To reset, run:
  ```bash
  docker compose down
  docker volume rm oempro_oempro_mysql_data
  ```
- **First-time setup**: Docker Compose automatically creates the volume on first run
- **Keep override file local**: Don't commit `docker-compose.override.yml` to git - it's Mac-specific

### Alternative: Use mysqldump for Cross-Platform

If you prefer logical backups that work across platforms:

```bash
# On production (creates SQL dump)
docker exec oempro_mysql mysqldump -u root -p'password' --all-databases > dump.sql

# On macOS (restore SQL dump)
docker exec -i oempro_mysql mysql -u root -p'password' < dump.sql
```

Note: mysqldump is slower and causes brief locks, but produces platform-independent backups.

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
