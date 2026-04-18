# Blueprint v3 — Amendments (April 12, 2026)

> Apply these changes to `2026_Local_Intelligence_Hub_Blueprint_v3.md`.

---

## 1. In the "Documentation (The Portfolio)" section, extend the ADR list:

Add these entries after ADR-009:

- **ADR-010:** Why Ollama lifecycle via user LaunchAgent (replaces `launchctl setenv`)
- **ADR-011:** Why disable unattended macOS updates for home-lab continuity
- **ADR-012:** April 11 reboot incident retrospective — including the three hypothesis dead-ends

## 2. In the "Phase 1: AI & OpenClaw (The Brain)" → Ollama Configuration bullet list, replace:

> - `OLLAMA_HOST=0.0.0.0` via `launchctl setenv` — LAN-accessible

with:

> - Lifecycle managed by user LaunchAgent at `~/Library/LaunchAgents/com.fitz.ollama.plist`. All environment variables (`OLLAMA_HOST=0.0.0.0`, `OLLAMA_NUM_PARALLEL=2`, `OLLAMA_KEEP_ALIVE=24h`, plus Homebrew's `OLLAMA_FLASH_ATTENTION=1` and `OLLAMA_KV_CACHE_TYPE=q8_0`) are baked into the plist. Homebrew manages the binary, the operator owns the service definition. See ADR-010.
> - `brew services` is **not** used for Ollama. Do not use `launchctl setenv` — it is session-scoped and lost on reboot (ADR-012).

## 3. In the "Phase 2: Media & Streaming" → "Storage Strategy" block, append after the "Critical for hardlinks" bullet:

> **Known fragility until NAS migration:** macOS updates can reset OrbStack's TCC grant to access `/Volumes/T7`, causing every container that mounts the external SSD to fail to start. This is the primary reason the Q3 2026 UniFi NAS migration is on the roadmap — network-share mounts don't have this class of TCC dependency. Until then, every macOS update is followed by the post-reboot verification checklist (ADR-011) to catch any regression. See ADR-012 for the incident that surfaced this.

## 4. Add a new top-level section before "Backup Strategy":

```
## 🛡️ Host OS Policy

**macOS automatic updates are disabled** (ADR-011). The single event of an unattended reboot
exposed enough latent failure modes (ADR-012) that operator-controlled reboots are the new baseline.

Updates cadence: check weekly, apply manually during maintenance windows using
`sudo fdesetup authrestart` for FileVault passthrough. After each reboot, run the
post-reboot verification checklist (see ADR-011) before declaring the lab available.

This trades unattended security patching for reboot-timing control. Acceptable for a LAN-only
home lab with no public ingress — remote access is relay-based via UniFi Teleport with no open ports (ADR-004).
```

## 5. Optionally, update the April 2026 row of the timeline table:

Add a note about ADR-010/011/012 being written as part of the Phase 1 doc backlog.
