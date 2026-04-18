# Progress Tracker — Phase 3 Completion (April 18, 2026)

> Apply these changes to `Local_Intelligence_Hub_Progress_Tracker.md`.

---

## 1. Mark Phase 3 checklist items complete:

- [x] Deploy Paperless-ngx (with Redis, Gotenberg, Tika)
- [x] Deploy Actual Budget
- [x] Create superusers for both services
- [x] Configure OCR languages (eng + rus + ukr)
- [x] Fix Paperless crash (trash dir, OCR_LANGUAGES vs OCR_LANGUAGE, filename format syntax)
- [x] Test OCR — document ingested and extracted successfully
- [x] Backup script: hub-backup.sh exports Paperless + tars Actual Budget to Google Drive
- [x] LaunchAgent com.fitz.hub-backup.plist — daily at 04:00
- [x] Scripts and LaunchAgent pushed to GitHub
- [ ] Phase 3 ADRs (Paperless selection, Actual Budget selection, backup strategy)

## 2. Add to Phase 3 Notes:

- Paperless-ngx crash on first deploy was caused by three issues:
    1. PAPERLESS_TRASH_DIR pointed to a path that did not exist — must create on host at
       ~/docker/configs/paperless/media/trash (not via docker compose run)
    2. PAPERLESS_OCR_LANGUAGE selects languages; PAPERLESS_OCR_LANGUAGES (plural) installs them
    3. Filename format uses Jinja2 double-curly syntax: {{ created_year }}, not {created_year}
- Backup strategy: rclone + Google Drive (gdrive:hub-backups). OAuth tokens in
  ~/.config/rclone/rclone.conf (not in repo). Script at ~/bin/hub-backup.sh, LaunchAgent at
  ~/Library/LaunchAgents/com.fitz.hub-backup.plist. 30-day retention on remote.
- Paperless export uses built-in document_exporter --zip for consistent, restorable backups.
- Actual Budget backed up as a tar of ~/docker/configs/actual-budget/.
