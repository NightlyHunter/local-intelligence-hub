# ADR-011: Disable Unattended macOS Updates

**Status:** Accepted
**Date:** 2026-04-12
**Category:** Infrastructure — Host OS Policy
**Related:** ADR-010, ADR-012 (April 11 incident)

## Context

macOS Tahoe 26.4.1 installed itself unattended at 23:43 on April 11, 2026, rebooting the Mac Studio. A single reboot exposed two independent latent failures (see ADR-012): Ollama lost its LAN binding, and five containers failed to restart due to a TCC permission reset on `/Volumes/T7`. No alerting existed; the outage was discovered ~18 hours later.

macOS's default behavior for a Mac signed into iCloud is to install updates automatically during a nightly window, with no operator involvement. This is the right default for a laptop used by a non-technical owner. It is the wrong default for a host whose primary job is to provide 24/7 services to other devices.

## Decision

Disable macOS automatic update installation. Updates will continue to be **checked** and **downloaded** automatically (so the operator knows when one is available), but **installation and the resulting reboot** require explicit operator action. Updates are applied during windows where the operator can use `fdesetup authrestart` for headless FileVault passthrough and verify post-reboot service health.

## Rationale

1. **The forcing function that caused April 11's outage is removable.** The incident was not caused by a bug; it was caused by a reboot at an inconvenient moment with no operator present to handle aftermath. Eliminating unattended reboots eliminates an entire class of future incidents.

2. **Home-lab uptime beats unattended patching for this threat model.** Unattended patching matters most on edge devices with weak human maintenance cycles. A home lab with an active operator, regular engagement, and documented manual-update procedures does not benefit from it. The security-vs-availability tradeoff here falls clearly on the availability side.

3. **Post-reboot verification is non-trivial.** April 11 demonstrated that a reboot can silently break LAN-visible Ollama and any container with an external-volume dependency. A human-in-the-loop update is the only realistic way to catch these quickly.

4. **Manual updates compose with the existing `fdesetup authrestart` practice.** ADR-004's operational notes already require `fdesetup authrestart` for planned reboots to avoid FileVault boot-time lockout. Unattended updates bypass this; manual updates honor it.

## Trade-offs

- **Delayed security patches.** Critical CVEs in macOS are now on operator-applied cadence, not Apple's. Mitigated by: the Mac Studio is LAN-only (no public ingress; Tailscale handles all remote access — see ADR-004), and critical updates will be applied during regular engagement with the lab (typically weekly).
- **Operator forgets to apply updates.** Realistic failure mode. Mitigated by: macOS still *notifies* about available updates via the default check-and-download behavior, and the operator engages with the lab frequently enough that a pending update badge will be noticed.
- **No protection against zero-days between available-update and operator-applied.** Accepted. The threat model for a LAN-only home server with no public attack surface does not justify unattended reboots.

## Procedure

### Disabling Auto-Install

System Settings → General → Software Update → (i) next to "Automatic Updates":
- **Check for updates:** ON (cheap, informative)
- **Download new updates when available:** ON (prepares install without committing)
- **Install macOS updates:** OFF ← the key change
- **Install application updates from the App Store:** operator preference
- **Install Security Responses and system files:** OFF (these can also reboot)

### Applying Updates Manually (Runbook)

1. Announce the maintenance window to any users of the lab.
2. Cleanly stop any in-flight work (active downloads in qBittorrent; any active Ollama inferences).
3. Trigger the update: System Settings → General → Software Update → Update Now.
4. When prompted to restart, use:
   ```bash
   sudo fdesetup authrestart
   ```
   This caches the FileVault key for one reboot cycle, letting the Mac boot past FileVault without physical keyboard input — required for headless remote recovery.
5. After reboot, verify service health (see Post-Reboot Checklist below).

### Post-Reboot Checklist

Run these before declaring the system healthy:

```bash
# 1. Ollama: listening on *:11434 (not localhost)
lsof -i :11434

# 2. Ollama: serving API
curl -s http://localhost:11434/api/tags | head -c 100

# 3. Docker/OrbStack: all expected containers running
docker ps --format "table {{.Names}}\t{{.Status}}" | sort

# 4. Any stopped containers: check their Error field (TCC regressions surface here)
for c in $(docker ps -aq --filter status=exited); do
  echo "=== $(docker inspect $c --format '{{.Name}}') ==="
  docker inspect $c --format '{{.State.Error}}'
done

# 5. External SSD mount visible to Docker
docker run --rm -v /Volumes/T7/media:/test alpine ls /test

# 6. VPN still working (gluetun should report Netherlands IP)
docker exec gluetun wget -qO- ifconfig.me
```

Any failure in steps 1–6 should be resolved before declaring the lab available. ADR-012's diagnostic pattern (`docker inspect ... '{{.State.Error}}'`) is the first-line check for step 4.

## Alternatives Considered

| Option | Why Rejected |
|---|---|
| Keep auto-updates on; add monitoring/alerting to catch post-reboot failures after the fact | Bandages the symptom; doesn't remove the root cause; adds infrastructure to maintain |
| Keep auto-updates on; schedule them during operator-awake hours via MDM profile | No MDM in this home lab; Apple's update scheduling is not reliably granular for this |
| Delay updates by N days (corporate-style) via `softwareupdate --ignore` | Deprecated behavior in recent macOS; Apple has deliberately made delayed updates harder |
| Disable FileVault so auto-reboots don't need authrestart | Reduces at-rest encryption for theft protection; larger security regression than the one this ADR avoids |

## Operational Notes

- Check update state from CLI: `softwareupdate --list`.
- History of applied updates: `softwareupdate --history | head -20`.
- If an update was silently applied despite settings (bugs happen): `last reboot | head` and `softwareupdate --history` will reveal it.
- This ADR applies only to macOS itself. Homebrew, Docker image updates via Watchtower, and Ollama binary updates remain on their own automated cadences — none of them trigger reboots.
