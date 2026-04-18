# Blueprint — Phase 3 Backup Strategy Amendment (April 18, 2026)

> Apply these changes to the blueprint (currently v4).

---

## 1. Replace or create the Backup Strategy section:

### Backup Strategy

What is backed up: Paperless-ngx (full document export via document_exporter --zip) and
Actual Budget (tar of config directory).

Where: Google Drive via rclone (gdrive:hub-backups remote). OAuth tokens stored locally
at ~/.config/rclone/rclone.conf — never committed to the repo.

Schedule: Daily at 04:00 via LaunchAgent (com.fitz.hub-backup.plist).

Retention: 30 days on Google Drive. Older backups auto-deleted by the script.

What is NOT backed up (by design):
- Media files (movies/tv/music on /Volumes/T7) — re-downloadable, not worth the bandwidth
- Container configs for stateless services (gluetun, FlareSolverr, Watchtower) — recreatable
  from docker-compose.yml
- Ollama models — re-pullable from the registry

Recovery:
- Paperless: document_importer against the exported zip
- Actual Budget: extract tar to ~/docker/configs/actual-budget/, restart container

Future (September 2026): When the UniFi NAS arrives, evaluate local backup targets
(NAS RAID 1) as a second copy alongside Google Drive (3-2-1 backup pattern).

## 2. In the ADR list, add:

- ADR-013: Backup strategy — rclone to Google Drive, Paperless export + Actual Budget tar,
  daily schedule, 30-day retention (pending — to be written)

## 3. In the timeline table, add to April 2026:

Phase 3 complete: Paperless-ngx + Actual Budget fully operational. Automated daily backups
to Google Drive via rclone.
