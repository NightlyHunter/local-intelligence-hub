# ADR-010: Ollama Lifecycle via User LaunchAgent

**Status:** Accepted
**Date:** 2026-04-12
**Category:** Phase 1 — AI Infrastructure
**Supersedes (partially):** `phase-1-ai-setup.md` § Environment Variables
**Related:** ADR-001 (Ollama native), ADR-012 (April 11 incident)

## Context

Phase 1 setup configured Ollama's LAN binding by running:

```bash
launchctl setenv OLLAMA_HOST 0.0.0.0
brew services restart ollama
```

This worked for 12 days until the April 11 reboot exposed the gap: **`launchctl setenv` is scoped to the current launchd user session and its values are cleared on reboot.** On next boot, Homebrew's Ollama LaunchAgent launched with no `OLLAMA_HOST` set, defaulting Ollama to `127.0.0.1:11434` — invisible to every LAN client. See ADR-012 for the full incident.

Homebrew's template plist (`/opt/homebrew/Cellar/ollama/<version>/homebrew.mxcl.ollama.plist`) does support an `EnvironmentVariables` block, but editing it is not a viable fix: `brew upgrade ollama` installs into a new versioned Cellar directory and any edits are lost.

## Decision

Replace Homebrew's managed Ollama service with a user-owned LaunchAgent at `~/Library/LaunchAgents/com.fitz.ollama.plist` that bakes all required environment variables into the plist itself. `brew services` is permanently stopped for Ollama; Homebrew continues to manage the binary (install/upgrade), but lifecycle and configuration are owned by the operator.

## Rationale

1. **Environment is part of the service definition, not session state.** LaunchAgents load their `EnvironmentVariables` block at every service start — including at boot, before any user login session exists. No `launchctl setenv` equivalent is needed because the env vars are declared where launchd can see them unconditionally.

2. **Decoupled from Homebrew's upgrade cycle.** The plist lives in the user's `~/Library/LaunchAgents/`, a path Homebrew never writes to. `brew upgrade ollama` replaces the binary at `/opt/homebrew/opt/ollama/bin/ollama` (a stable symlink to the current version) but does not touch the user LaunchAgent. One post-upgrade command picks up the new binary:
   ```bash
   launchctl kickstart -k gui/$(id -u)/com.fitz.ollama
   ```

3. **All production env vars in one declarative file.** The plist includes `OLLAMA_HOST`, `OLLAMA_NUM_PARALLEL`, `OLLAMA_KEEP_ALIVE`, `OLLAMA_FLASH_ATTENTION`, and `OLLAMA_KV_CACHE_TYPE`. The last two are carried forward from Homebrew's template (Flash Attention for Apple Silicon inference speedup; `q8_0` KV cache quantization to halve KV memory footprint with minimal quality impact).

4. **`LimitLoadToSessionType` covers all contexts.** Including `Aqua`, `Background`, `LoginWindow`, `StandardIO`, and `System` ensures the service runs in GUI sessions, headless SSH, pre-login states, and anything else launchd might present. Carried forward from Homebrew's template.

5. **Authoritative logging destination.** `StandardOutPath` and `StandardErrorPath` route all Ollama output to `/opt/homebrew/var/log/ollama.log`, matching Homebrew's convention so existing log-analysis habits still work.

## Trade-offs

- **One-command maintenance after `brew upgrade ollama`.** The running Ollama process uses the old binary until `launchctl kickstart -k` restarts it. Acceptable — Homebrew upgrades are operator-initiated.
- **Operator now owns the service definition.** If Ollama's upstream defaults change in a way that affects the plist (e.g., a new required env var), the operator must update `com.fitz.ollama.plist`. Acceptable — this is true of any infrastructure-as-code.
- **`brew services list` reports Ollama as stopped.** This is correct and intended but may confuse future operators reading the list. Documented here and in the Phase 1 setup guide.

## Plist Contents

Location: `~/Library/LaunchAgents/com.fitz.ollama.plist`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.fitz.ollama</string>
    <key>ProgramArguments</key>
    <array>
        <string>/opt/homebrew/opt/ollama/bin/ollama</string>
        <string>serve</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>OLLAMA_HOST</key>
        <string>0.0.0.0</string>
        <key>OLLAMA_NUM_PARALLEL</key>
        <string>2</string>
        <key>OLLAMA_KEEP_ALIVE</key>
        <string>24h</string>
        <key>OLLAMA_FLASH_ATTENTION</key>
        <string>1</string>
        <key>OLLAMA_KV_CACHE_TYPE</key>
        <string>q8_0</string>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>LimitLoadToSessionType</key>
    <array>
        <string>Aqua</string>
        <string>Background</string>
        <string>LoginWindow</string>
        <string>StandardIO</string>
        <string>System</string>
    </array>
    <key>WorkingDirectory</key>
    <string>/opt/homebrew/var</string>
    <key>StandardOutPath</key>
    <string>/opt/homebrew/var/log/ollama.log</string>
    <key>StandardErrorPath</key>
    <string>/opt/homebrew/var/log/ollama.log</string>
</dict>
</plist>
```

## Alternatives Considered

| Option | Why Rejected |
|---|---|
| Edit Homebrew's Cellar plist in-place | Lost on every `brew upgrade ollama` (new versioned path) |
| Write a `~/bin/ollama-wrapper.sh` that exports env vars and execs ollama, invoked by a LaunchAgent | Works but adds an intermediate shell process for no real benefit over declaring env vars in the plist directly |
| `launchctl setenv` in a boot-time script (e.g., login item) | Still session-scoped conceptually; fragile; does not run pre-login |
| Accept ephemeral env and re-run `launchctl setenv` manually after each reboot | Explicitly what April 11 exposed as unacceptable |
| Run Ollama in Docker with env vars in the compose file | Forfeits Metal GPU and full unified memory access — see ADR-001 |

## Operational Notes

- **Deploy/reload after edits:**
  ```bash
  launchctl unload ~/Library/LaunchAgents/com.fitz.ollama.plist
  launchctl load ~/Library/LaunchAgents/com.fitz.ollama.plist
  ```
- **Restart to pick up a new binary after `brew upgrade ollama`:**
  ```bash
  launchctl kickstart -k gui/$(id -u)/com.fitz.ollama
  ```
- **Verify health (three independent signals):**
  ```bash
  launchctl list | grep com.fitz.ollama            # PID, exit code 0
  lsof -i :11434                                    # TCP *:11434 (LISTEN) — note the * not localhost
  curl -s http://localhost:11434/api/tags | head    # JSON response with model list
  ```
- **Validate plist syntax before loading:** `plutil -lint ~/Library/LaunchAgents/com.fitz.ollama.plist`
- **Rollback path:** `launchctl unload` the custom plist, then `brew services start ollama` restores Homebrew's management.
