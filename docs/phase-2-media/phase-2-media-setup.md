# Phase 2: Media & Streaming — Setup Guide

> **Hardware:** Mac Studio, 1TB External SSD (`/Volumes/T7`)
> **Started:** April 4, 2026
> **Stack:** gluetun, qBittorrent, FlareSolverr, Prowlarr, Radarr, Sonarr, Lidarr, Jellyfin, Jellyseerr, Watchtower

---

## Overview

Phase 2 deploys a complete media acquisition and streaming pipeline. Users search for content via Jellyseerr, which dispatches requests to Radarr/Sonarr. These query Prowlarr for indexer results, send downloads to qBittorrent (routed through a VPN), and Jellyfin serves the final library for playback.

All containers run in OrbStack via a single Docker Compose file.

**Architecture:**

```
┌──────────┐     ┌────────────┐     ┌──────────┐     ┌───────────┐
│Jellyseerr│────►│Radarr/Sonarr│────►│ Prowlarr  │────►│ Indexers   │
│  :5055   │     │ /Lidarr    │     │  :9696   │     │(1337x,etc)│
└──────────┘     └─────┬──────┘     └──────────┘     └───────────┘
                       │
                       ▼
              ┌──────────────────┐
              │    qBittorrent    │
              │  (inside gluetun) │───► ProtonVPN (WireGuard)
              │      :8080       │     Netherlands exit
              └────────┬─────────┘
                       │ hardlink
                       ▼
              ┌──────────────────┐
              │     Jellyfin      │
              │      :8096       │───► Playback (LAN / UniFi Teleport)
              └──────────────────┘
```

---

## 1. Storage Layout

All media lives on a 1TB external SSD mounted at `/Volumes/T7`. Config data lives on the internal SSD for performance.

### Media Directory Structure

```
/Volumes/T7/media/
├── downloads/
│   ├── movies/    ← qBittorrent category: radarr
│   ├── tv/        ← qBittorrent category: sonarr
│   └── music/     ← qBittorrent category: lidarr
├── movies/        ← Organized library (hardlinks from downloads)
├── tv/
└── music/
```

### Config Data

```
~/docker/configs/
├── radarr/
├── sonarr/
├── lidarr/
├── prowlarr/
├── jellyfin/
├── jellyseerr/
├── qbittorrent/
└── gluetun/
```

### Hardlinks — The Critical Detail

When Radarr "imports" a completed download, it creates a **hardlink** rather than copying the file. This means the file exists in both `downloads/movies/` and `movies/` but uses disk space only once. Without hardlinks, every import doubles disk usage — fatal on a 1TB drive.

**Hardlinks only work when source and destination are on the same filesystem and mount point.** Inside Docker, this means both qBittorrent and the arr apps must mount the **same parent volume**:

```yaml
# CORRECT — same mount point, hardlinks work
qbittorrent:
  volumes:
    - /Volumes/T7/media:/media
radarr:
  volumes:
    - /Volumes/T7/media:/media

# WRONG — different mount points, hardlinks fail silently (falls back to copy)
qbittorrent:
  volumes:
    - /Volumes/T7/media/downloads:/downloads    # ← different root
radarr:
  volumes:
    - /Volumes/T7/media:/media
```

**Verify hardlinks are working:**
```bash
# Same inode number = hardlink (single copy on disk)
ls -li /Volumes/T7/media/downloads/movies/SomeMovie/SomeMovie.mkv
ls -li /Volumes/T7/media/movies/SomeMovie/SomeMovie.mkv
# Both should show the same inode (first number in output)
```

**qBittorrent gotcha:** qBittorrent has a separate "Keep incomplete torrents in" (temp folder) setting. After changing the main volume mount, this temp path must also be updated or disabled — the old path causes "Permission denied" errors.

---

## 2. Docker Compose Structure

The entire stack is defined in `~/docker/docker-compose.yml` with secrets in `~/docker/.env` (gitignored). A sanitized version is pushed to the repo.

### Key Networking Patterns

**gluetun + qBittorrent (VPN kill switch):**
```yaml
gluetun:
  image: qmcgaw/gluetun
  ports:
    - 8080:8080    # qBittorrent WebUI (exposed through gluetun)
  environment:
    - VPN_SERVICE_PROVIDER=protonvpn
    - VPN_TYPE=wireguard
    - SERVER_COUNTRIES=Netherlands
    # ... WireGuard private key in .env

qbittorrent:
  image: linuxserver/qbittorrent
  network_mode: "service:gluetun"    # ← shares gluetun's network entirely
  volumes:
    - /Volumes/T7/media:/media
    - ~/docker/configs/qbittorrent:/config
```

qBittorrent has **no network of its own**. If the VPN tunnel drops, it has zero internet connectivity. See [ADR-008](../decisions/ADR-008-gluetun-vpn-kill-switch.md).

**Standard services (default bridge network):**
```yaml
radarr:
  image: linuxserver/radarr
  ports:
    - 7878:7878
  volumes:
    - /Volumes/T7/media:/media
    - ~/docker/configs/radarr:/config

# Same pattern for sonarr (:8989), lidarr (:8686), prowlarr (:9696),
# jellyfin (:8096), jellyseerr (:5055)
```

All non-VPN containers use Docker's default bridge network and can reach each other by service name (e.g., `http://radarr:7878`).

---

## 3. VPN (gluetun + ProtonVPN)

### Setup

1. Generate WireGuard credentials at `account.protonvpn.com` → Downloads → WireGuard configuration.
   - Platform: Linux
   - VPN Accelerator: On
   - All other options: Off
2. Extract the private key and add it to `~/docker/.env`.
3. Configure gluetun environment variables in the compose file.

### Verify VPN

```bash
# Should return a Netherlands IP, not your home IP
docker exec gluetun wget -qO- ifconfig.me
```

### Why WireGuard, Not OpenVPN

OpenVPN was attempted first but failed: DNS resolution timed out inside the tunnel, and there were route conflicts with OrbStack's virtual networking. WireGuard connected immediately with no issues.

---

## 4. FlareSolverr

FlareSolverr is a proxy server that solves Cloudflare challenges for indexers that use Cloudflare protection (1337x, EZTV).

```yaml
flaresolverr:
  image: ghcr.io/flaresolverr/flaresolverr
  ports:
    - 8191:8191
```

- Configured in Prowlarr as a tag, not globally — only applied to indexers that actually need it.
- Challenge solving takes ~11 seconds per request.
- Not all indexers need it — only tag indexers that return Cloudflare errors.

---

## 5. Prowlarr (Indexer Manager)

Prowlarr manages indexer configuration centrally and syncs to all arr apps automatically.

### Indexers

| Indexer | Type | FlareSolverr | Notes |
|---|---|---|---|
| 1337x | Public | Yes | Magnet links only (torrent file downloads timeout even with FlareSolverr) |
| EZTV | Public | Yes | TV-focused |
| LimeTorrents | Public | No | General |
| RuTracker | Semi-private | No | Best source for multi-audio/dual-audio releases; free registration required |
| KickassTorrents | Public | No | No registration needed |
| Kinozal | Semi-private | Possibly | Free registration; good for multi-audio alongside RuTracker |

### 1337x Magnet Link Fix

1337x torrent file downloads timed out even with FlareSolverr solving the Cloudflare challenge. Fix: in Prowlarr's 1337x indexer settings, enable "Prefer Magnet Links." Magnets bypass the file download entirely.

### App Sync

After adding Radarr, Sonarr, and Lidarr as Apps in Prowlarr (Settings → Apps), indexers sync automatically. No manual indexer configuration needed in individual arr apps.

---

## 6. Radarr / Sonarr / Lidarr

All three follow the same pattern:

### Configuration per App

| Setting | Radarr | Sonarr | Lidarr |
|---|---|---|---|
| Root folder | `/media/movies` | `/media/tv` | `/media/music` |
| Download client | qBittorrent (via gluetun) | qBittorrent (via gluetun) | qBittorrent (via gluetun) |
| qBittorrent category | `radarr` | `sonarr` | `lidarr` |
| Download priority (recent) | First | High | Normal |
| Download priority (older) | High | Normal | Low |

### Download Client Setup

Each arr app connects to qBittorrent at `localhost:8080` (since qBittorrent shares gluetun's network, and gluetun exposes 8080).

**qBittorrent category paths:** Each category has a relative save path configured in qBittorrent:
- `radarr` → `movies/`
- `sonarr` → `tv/`
- `lidarr` → `music/`

These are relative to qBittorrent's default save path (`/media/downloads/`), resulting in files landing at `/media/downloads/movies/`, `/media/downloads/tv/`, etc.

**Sonarr path gotcha:** qBittorrent's `sonarr` category already saves to `tv/`. Do NOT set Sonarr's download path to include `tv/` — this causes a double path (`/downloads/tv/tv/`).

### Remote Path Mappings

After the hardlink fix (changing qBittorrent's volume mount to `/media`), remote path mappings are **not needed** and should be removed if present. Both the arr apps and qBittorrent see the same `/media` root, so paths match without translation.

### Download Priorities

Configured in Settings → Download Clients → Priority within each app. Movies get highest priority (most likely to be watched immediately), music gets lowest. qBittorrent's queue respects these priorities — higher-priority torrents download before lower-priority ones. Works best with conservative active download limits.

### Custom Formats (Radarr)

Custom Formats created for multi-audio track preferences:

| Custom Format | Score | Regex Pattern |
|---|---|---|
| Multi/Dual Audio | 100 | Matches release names containing "multi" or "dual" audio indicators |
| Russian Audio | 50 | Matches Russian language indicators in release names |
| Ukrainian Audio | 50 | Matches Ukrainian language indicators in release names |

Quality Profile configuration: Upgrades Allowed = true, Upgrade Until Custom Format Score = 200.

**Status:** Created but scoring needs debugging — RuTracker results not triggering upgrades as expected. Check Activity → History for rejection reasons.

---

## 7. Jellyfin

Jellyfin is the media server and player.

### Libraries

| Library | Path | Content |
|---|---|---|
| Movies | `/media/movies` | Films imported by Radarr |
| TV Shows | `/media/tv` | Series imported by Sonarr |
| Music | `/media/music` | Albums imported by Lidarr |

### Access

- **LAN:** `http://<mac-studio-ip>:8096`
- **Remote:** Same LAN URL, connected via UniFi Teleport (see ADR-004)
- **Future (Phase 5):** Public URL via Cloudflare Tunnel for friends/family streaming

### Hardware Transcoding

Pending configuration. The Mac Studio's media engine supports VideoToolbox for hardware-accelerated transcoding. This will be needed for Phase 5 (remote streaming) where 4K content must be downscaled to 1080p due to the 40 Mbps upload limit. Testing deferred until NAS arrival.

---

## 8. Jellyseerr

Jellyseerr is the user-facing request layer. See [ADR-007](../decisions/ADR-007-jellyseerr-request-layer.md) for why it exists.

### Setup

1. Signed in using Jellyfin authentication (`http://jellyfin:8096` — Docker internal DNS).
2. Connected Radarr (`http://radarr:7878`) with API key from Radarr → Settings → General.
3. Connected Sonarr (`http://sonarr:8989`) with API key from Sonarr → Settings → General.

### Request Flow

```
Family member searches "Начало" (Russian)
    → Jellyseerr queries TMDb → finds "Inception" (canonical English)
    → User clicks "Request"
    → Jellyseerr sends to Radarr (English title + TMDb ID)
    → Radarr searches via Prowlarr → qBittorrent downloads
    → Jellyfin library updated → ready to watch
```

### Access

- `http://<mac-studio-ip>:5055` (LAN)
- Same URL remote, via UniFi Teleport (see ADR-004)

---

## 9. Watchtower

Watchtower automatically updates all container images. See [ADR-009](../decisions/ADR-009-watchtower-automated-updates.md).

```yaml
watchtower:
  image: containrrr/watchtower
  volumes:
    - /var/run/docker.sock:/var/run/docker.sock
  environment:
    - WATCHTOWER_CLEANUP=true                  # Remove old images
    - WATCHTOWER_SCHEDULE=0 0 4 * * *          # Daily at 4am
```

### Operational Commands

```bash
# Check update history
docker logs watchtower

# Trigger immediate check
docker exec watchtower /watchtower --run-once

# Exclude a container from auto-updates (add to compose)
labels:
  - "com.centurylinklabs.watchtower.enable=false"
```

**Cascading restart note:** When Watchtower updates gluetun, qBittorrent also restarts (due to `network_mode: "service:gluetun"`). Active downloads pause and resume automatically. This is expected.

---

## 10. qBittorrent Tuning

### Recommended Limits (1TB SSD)

| Setting | Value | Reason |
|---|---|---|
| Max active downloads | 3 | Conserve SSD space |
| Max active uploads | 5 | Maintain ratio |
| Max active torrents | 8 | Overall cap |

Increase these after NAS arrives with more storage headroom.

### Category Save Paths

Configured in qBittorrent → Options → Downloads → Default Save Path: `/media/downloads/`

Categories:
- `radarr` → relative path: `movies/`
- `sonarr` → relative path: `tv/`
- `lidarr` → relative path: `music/`

---

## Service Quick Reference

| Service | Port | URL (LAN) | Purpose |
|---|---|---|---|
| qBittorrent | 8080 | `http://localhost:8080` | Torrent client |
| FlareSolverr | 8191 | `http://localhost:8191` | Cloudflare bypass |
| Prowlarr | 9696 | `http://localhost:9696` | Indexer manager |
| Radarr | 7878 | `http://localhost:7878` | Movie management |
| Sonarr | 8989 | `http://localhost:8989` | TV management |
| Lidarr | 8686 | `http://localhost:8686` | Music management |
| Jellyfin | 8096 | `http://localhost:8096` | Media server |
| Jellyseerr | 5055 | `http://localhost:5055` | Request interface |
| Watchtower | — | N/A | Auto-updater |

---

## Troubleshooting

### VPN not connected

```bash
# Check gluetun logs
docker logs gluetun

# Verify external IP
docker exec gluetun wget -qO- ifconfig.me
# Should be a Netherlands IP
```

### Downloads not starting

1. Check gluetun is healthy: `docker ps` — look for health status.
2. Check qBittorrent logs: `docker logs qbittorrent`.
3. Verify Prowlarr can reach indexers: test search in Prowlarr UI.
4. Check arr app Activity → Queue for status messages.

### Hardlinks not working (files being copied instead)

```bash
# Compare inodes — same number = hardlink, different = copy
ls -li /Volumes/T7/media/downloads/movies/SomeMovie/file.mkv
ls -li /Volumes/T7/media/movies/SomeMovie/file.mkv
```

If inodes differ: verify both qBittorrent and the arr app mount the same volume (`/Volumes/T7/media:/media`). Remove any remote path mappings.

### Indexer search returns nothing

- Check FlareSolverr is running (for Cloudflare-protected indexers).
- Verify the indexer is tagged with the FlareSolverr tag in Prowlarr.
- For 1337x: ensure "Prefer Magnet Links" is enabled.
- Test the indexer directly in Prowlarr (Indexers → test icon).

### Jellyseerr can't find content by non-English title

This works via TMDb. If a title isn't found, TMDb may not have the localized entry. Try searching by the English title as a workaround, or add the TMDb entry yourself.

---

## Lessons Learned

1. **Hardlinks require matching mount points.** This is the single most impactful configuration detail. Getting it wrong silently doubles disk usage.
2. **`network_mode: "service:gluetun"` is the correct kill switch pattern.** Application-level VPN binding has race conditions; container-level isolation does not.
3. **OpenVPN fails with OrbStack; WireGuard works.** DNS resolution and route conflicts make OpenVPN unreliable inside OrbStack's virtual networking. Don't waste time debugging — use WireGuard.
4. **FlareSolverr is per-indexer, not global.** Tag only indexers that need it. Applying it globally adds 11 seconds of latency to every search.
5. **1337x needs magnet links.** Torrent file downloads time out even with FlareSolverr. Magnets bypass the problem entirely.
6. **Prowlarr app sync eliminates manual indexer config.** Add indexers once in Prowlarr, add arr apps under Settings → Apps, everything syncs automatically.
7. **qBittorrent category paths are relative.** If the category save path is `movies/` and the default save path is `/media/downloads/`, files land at `/media/downloads/movies/`. Don't duplicate the path in the arr app's download settings.
8. **Watchtower + gluetun = cascading restarts.** Expected behavior, not a bug. Downloads auto-resume.
