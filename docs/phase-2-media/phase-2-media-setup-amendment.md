# Phase 2 Setup Guide — Amendment (April 12, 2026)

> Apply these additions to `phase-2-media-setup.md`. Rather than republish the full guide, this patch file describes the two sections to add/revise.

---

## New section: insert after "Storage Layout" → "Hardlinks — The Critical Detail"

### Known Risk: TCC Fragility of External Volumes on macOS (Until NAS Migration)

The Mac Studio mounts `/Volumes/T7` as an external APFS volume, and OrbStack requires explicit macOS TCC (Transparency, Consent, and Control) grants to bind-mount paths under `/Volumes/*` into containers. **Every macOS update carries a non-zero risk of resetting OrbStack's TCC grant.** When this happens, Docker cannot access `/Volumes/T7` and every container that mounts it fails to start with:

```
error while creating mount source path '/Volumes/T7/media': mkdir /Volumes/T7: permission denied
```

This is how the April 11 incident presented (see ADR-012). The five affected containers are **qbittorrent, radarr, sonarr, lidarr, and jellyfin** — every container that mounts `/Volumes/T7/media:/media`. Containers without external-volume dependencies (gluetun, prowlarr, jellyseerr, flaresolverr, plus the paperless stack) are unaffected and restart cleanly.

This fragility is known, accepted, and time-bounded. The Q3 2026 UniFi NAS migration replaces external-volume mounts with network-share mounts, eliminating this class of failure.

**Post-reboot recovery:**

1. Check whether the mount is actually visible:
   ```bash
   ls -la /Volumes/T7
   docker run --rm -v /Volumes/T7/media:/test alpine ls /test
   ```
   If the alpine mount test succeeds, the mount works and TCC has been re-granted automatically. Proceed to step 4.
2. If the alpine test fails with a permission error: System Settings → Privacy & Security → **Files and Folders** → locate OrbStack → ensure "Removable Volumes" is enabled. If the entry is missing, check **Full Disk Access** and toggle OrbStack off and back on there.
3. Quit OrbStack fully (menu bar → Quit), reopen it, repeat the alpine test.
4. Restart the affected containers:
   ```bash
   cd ~/docker && docker compose up -d
   ```

---

## New subsection: add to "Troubleshooting" section

### Containers exit 137 with "permission denied" on `/Volumes/T7` after a reboot

Exit 137 is SIGKILL. In this environment, this code on a failed restart is almost always a TCC regression on the external SSD, not OOM or a crash. `docker ps` will not show the cause — use `docker inspect`:

```bash
for c in qbittorrent radarr sonarr lidarr jellyfin; do
  echo "=== $c ==="
  docker inspect $c --format 'Status={{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} err={{.State.Error}}'
done
```

`OOMKilled=false` with `err=` containing `permission denied` on `/Volumes/T7` is the TCC signature. Recovery procedure above.

---

## New subsection: add to "Lessons Learned"

- **First-line diagnostic when containers won't restart after a reboot is `docker inspect`'s `State.Error` field, not `docker ps` exit codes.** April 11's investigation spent 30+ minutes on wrong hypotheses (OOM, Watchtower cycle, restart policy) because the external-facing signal was just "exit 137" — but `{{.State.Error}}` held the real answer the whole time. See ADR-012 for the full retrospective.
