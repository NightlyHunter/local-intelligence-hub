# ADR-012: April 11 Reboot Incident — Retrospective and Hypothesis Record

**Status:** Accepted
**Date:** 2026-04-12
**Category:** Incident Review — cross-cutting (Phase 1 + Phase 2)
**Related:** ADR-010 (Ollama LaunchAgent), ADR-011 (Disable macOS auto-updates)

## Context

On April 11, 2026 at 23:43 local time, macOS Tahoe 26.4.1 installed itself unattended on the Mac Studio, triggering a reboot. The operator noticed the next day at ~18:00 that Ollama was unreachable from the MacBook and five containers in the media stack were stopped. This ADR documents both the final root causes and — more importantly — the three incorrect hypotheses that were pursued during diagnosis, since the debugging path itself holds more engineering value than the fix.

## Decision

Record the incident, its two independent root causes, the three hypothesis dead-ends, and the architectural weaknesses surfaced, as a single retrospective ADR. Codify the resulting mitigations in ADR-010 and ADR-011.

## Final Root Causes (Two Independent Failures from One Trigger)

**Trigger:** macOS Tahoe 26.4.1 auto-update reboot at 23:43.

### Root Cause 1: Ollama bound to localhost after reboot

`launchctl setenv OLLAMA_HOST 0.0.0.0`, applied during initial Phase 1 setup, is **session-scoped** — it lives only in the current launchd user session and is cleared on reboot. Homebrew's Ollama plist launched at boot with no `OLLAMA_HOST` set, defaulting to loopback binding (`127.0.0.1:11434`). Ollama appeared healthy to local clients and to `brew services list`, but every LAN client (MacBook, OpenClaw on the Linux PC) failed to reach it.

**Fix:** See ADR-010 — Ollama now runs under a user-owned LaunchAgent at `~/Library/LaunchAgents/com.fitz.ollama.plist` with environment variables baked into the plist itself.

### Root Cause 2: External SSD TCC grant reset by macOS update

The Tahoe 26.4.1 installer reset OrbStack's TCC (Transparency, Consent, and Control) grants for access to `/Volumes/T7`. On reboot, Docker attempted to restart the five containers that mount `/Volumes/T7/media` (qbittorrent, radarr, sonarr, lidarr, jellyfin), and each failed with:

```
error while creating mount source path '/Volumes/T7/media': mkdir /Volumes/T7: permission denied
```

Docker surfaced this externally as exit code 137 in `docker ps`, which misleadingly looked like SIGKILL from OOM or a crash. The real error was only visible in the `State.Error` field via `docker inspect`. The four containers that did not depend on the external volume (gluetun, prowlarr, jellyseerr, flaresolverr, plus the paperless stack) restarted cleanly.

By the time investigation began (~18 hours post-reboot), the TCC grant had already been reinstated automatically or by a routine OS interaction, so the mount test succeeded and the `docker compose up -d` recovery worked without manual permission intervention.

## Hypothesis Dead-Ends (The Valuable Part)

Three hypotheses were pursued and discarded before the true cause was found. Each was plausible; each was wrong; each narrowed the search space.

### Hypothesis 1: Out-of-memory kill (OOM)

**Why it seemed right:** Exit 137 is SIGKILL (128 + 9). The kernel OOM killer uses SIGKILL. Five heavyweight containers (Jellyfin, qBittorrent, three arr apps) died simultaneously while lightweight containers survived — classic OOM-killer signature. The Mac Studio has 128GB unified memory shared between Ollama (which can claim ~70GB for a loaded 122B model) and OrbStack's VM. Memory pressure was a credible pattern.

**Why it was wrong:** `docker inspect` reported `OOMKilled: false` for every container — authoritative evidence that Docker did not kill them for memory pressure. The `log show ... "jetsam"` query returned only routine RunningBoard noise ("Ignoring jetsam update because this process is not memory-managed"), not actual process kills. No evidence of memory exhaustion at the macOS level in the relevant time window.

**Lesson:** Exit 137 looks like OOM but is just SIGKILL. Anything that sends SIGKILL — the kernel OOM killer, `docker kill`, a host shutdown, a misbehaving init system — produces exit 137. Always check `OOMKilled` explicitly; don't infer from the exit code alone.

### Hypothesis 2: Watchtower mid-cycle interruption

**Why it seemed right:** Watchtower is the only thing in the stack that routinely issues bulk `docker stop` commands. Its log showed:

```
time="2026-04-12T04:43:03Z" level=info msg="Waiting for running update to be finished..."
```

That timestamp matches the `FinishedAt` of the five dead containers to the millisecond. Watchtower appeared to have initiated an unscheduled update cycle at exactly the moment the containers died — with no "Session done" message following, suggesting it was interrupted mid-stop. A well-known Watchtower failure mode is self-updating and restarting partway through a cycle, orphaning the half-stopped containers. The theory fit the evidence.

**Why it was wrong:** `docker inspect watchtower` showed `RestartCount=0` and `StartedAt=2026-04-12T04:47:25Z`. Watchtower didn't restart itself — it was freshly started 4 minutes *after* the containers died, as part of the whole stack coming up post-reboot. The "Waiting for running update..." message was its last log line *before* the OS shutdown killed it, not evidence of an in-progress cycle gone wrong. Watchtower was a victim of the shutdown, not its cause.

**Lesson:** Log timestamps tell you when events happened, not which events caused which. When two systems log at the same second, the default assumption should be a shared upstream cause, not that one caused the other.

### Hypothesis 3: Inconsistent `restart:` policies

**Why it seemed right:** Having ruled out OOM and Watchtower, the cleanest remaining explanation for "some containers came back and others didn't" was a restart-policy asymmetry. Under `restart: unless-stopped`, containers that were *explicitly stopped* (Docker marks these as user-intent) do not auto-restart, while containers that *crashed* do. If Watchtower had issued graceful `docker stop` to the 5 dead containers right before the host went down, Docker would record them as "stopped by user" and `unless-stopped` would correctly leave them stopped on reboot — while other containers killed ungracefully by the VM shutdown would be recorded as crashed and auto-restart.

**Why it was wrong:** Every container in the stack had `restart: unless-stopped`. No asymmetry existed. `docker inspect $c --format '{{.HostConfig.RestartPolicy.Name}}'` returned `unless-stopped` uniformly for all nine containers checked.

**Lesson:** When a theory depends on an asymmetry in configuration, verify the configuration *is* asymmetric before building further reasoning on it.

## How the Real Cause Was Found

The breakthrough came from running `docker inspect` with a format string that included `.State.Error` rather than just exit code and OOM status. The `Error` field — which had been there the whole time but was not in the default `docker ps` output or earlier inspect queries — contained the plain-language answer:

```
Error=error while creating mount source path '/Volumes/T7/media': mkdir /Volumes/T7: permission denied
```

Once surfaced, the rest fell into place: the five dead containers all mount `/Volumes/T7/media`; the four survivors do not. The asymmetry wasn't in restart policy or in memory usage — it was in volume dependencies. An `alpine ls /test` bind-mount test confirmed the mount now worked (TCC had re-granted by the time investigation began).

**Lesson:** Docker exposes rich state in `docker inspect` beyond what `docker ps` summarizes. When exit codes look like one thing (OOM/SIGKILL) but the `OOMKilled` flag contradicts it, read every field in `State` including `Error`. That field would have shortcut the investigation by 30+ minutes.

## Architectural Weaknesses Exposed

The incident was a single trigger, but it exposed three distinct weaknesses that would have stayed latent without a forcing event:

1. **`launchctl setenv` is session-scoped.** The Phase 1 setup guide documented `launchctl setenv OLLAMA_HOST 0.0.0.0` as the way to configure Ollama's binding. The guide did not mention that this value is lost on reboot. It worked from initial setup on March 30 through April 11 only because the machine hadn't rebooted in that window. Any reboot would have exposed this.

2. **External volumes are a TCC-fragile dependency on macOS.** Every macOS update carries a non-zero probability of resetting TCC grants for third-party processes touching `/Volumes/*`. For a container stack where five of the most important services depend on an external SSD mount, this is a fragile configuration the blueprint already acknowledged (Phase 2 → Q3 2026 NAS migration specifically addresses this), but the operational risk during the interim was not written down.

3. **Unattended macOS updates are incompatible with a dependency-heavy home lab.** The root trigger was not malicious or unusual — it was Apple shipping a security patch, which is the behavior one generally wants. But the combination of (a) unattended install, (b) at an unpredictable time, (c) while the operator is asleep, and (d) with multiple latent config fragilities in the stack, produced silent multi-service failure with no alerting. Either the auto-update has to go, or monitoring/alerting has to exist to catch the result. The cheaper fix is removing the trigger.

## Mitigations

| Mitigation | ADR | Status |
|---|---|---|
| Ollama runs under user LaunchAgent with baked-in env vars | ADR-010 | Deployed |
| macOS automatic updates disabled; apply manually with `fdesetup authrestart` | ADR-011 | Pending (operator action) |
| Doc update: `phase-1-ai-setup.md` `launchctl setenv` section replaced | — | Pending |
| TCC fragility documented in `phase-2-media-setup.md` as a known risk until NAS migration | — | Pending |
| Recovery runbook: `docker inspect $c --format '{{.State.Error}}'` as the first check when containers fail to restart post-reboot | — | Pending |

## Alternatives Considered

| Alternative | Why Rejected |
|---|---|
| Write three separate ADRs (one per hypothesis dead-end) | Fragmented narrative; the value is in the sequence, not the individual wrong turns |
| Write only the fix ADRs (010, 011) and omit the retrospective | Loses the most portfolio-valuable content: the diagnostic reasoning. Post-mortems that show wrong turns are stronger evidence of engineering judgment than tidy post-hoc rationalizations |
| Treat this as a single-paragraph note in the progress tracker | Undersells the learning; the retrospective framing is the whole point |

## Operational Notes

- First-line diagnostic for "container won't restart after reboot":
  ```bash
  docker inspect <name> --format '{{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} err={{.State.Error}}'
  ```
  The `err=` field will short-circuit most investigations.
- For future macOS updates, follow the manual procedure in ADR-011, including the post-reboot checklist: Ollama LAN binding, `/Volumes/T7` access from OrbStack, arr container health.
- If `/Volumes/T7` mount appears healthy from the shell but Docker reports permission denied, toggle OrbStack's Full Disk Access grant off and back on in System Settings → Privacy & Security.
