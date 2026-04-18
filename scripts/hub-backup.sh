#!/bin/bash
set -euo pipefail
BACKUP_DIR="/tmp/hub-backup-$(date +%Y%m%d-%H%M%S)"
GDRIVE_PATH="gdrive:hub-backups"
RETAIN_DAYS=30
mkdir -p "$BACKUP_DIR"
echo "=== Paperless export ==="
docker exec paperless document_exporter ../export --zip
EXPORT_FILE=$(ls -t ~/docker/configs/paperless/export/*.zip 2>/dev/null | head -1)
if [[ -n "$EXPORT_FILE" ]]; then
  cp "$EXPORT_FILE" "$BACKUP_DIR/paperless-$(date +%Y%m%d).zip"
  echo "Paperless export: OK"
else
  echo "WARNING: No export zip found"
fi
echo "=== Actual Budget ==="
tar czf "$BACKUP_DIR/actual-budget-$(date +%Y%m%d).tar.gz" \
  -C ~/docker/configs actual-budget
echo "Actual Budget tar: OK"
echo "=== Uploading to Google Drive ==="
rclone copy "$BACKUP_DIR" "$GDRIVE_PATH" --progress
echo "Upload: OK"
echo "=== Cleaning remote backups older than ${RETAIN_DAYS}d ==="
rclone delete "$GDRIVE_PATH" --min-age "${RETAIN_DAYS}d"
echo "=== Cleanup ==="
rm -rf "$BACKUP_DIR"
rm -f "$EXPORT_FILE"
echo "=== Backup complete ==="
