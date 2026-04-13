# Phase 1: AI & OpenClaw — Setup Guide

> **Hardware:** Mac Studio, 128GB Unified Memory, 2TB Internal SSD
> **Completed:** March 30 – April 5, 2026
> **Revised:** April 12, 2026 — Ollama lifecycle migrated from `brew services` + `launchctl setenv` to a user LaunchAgent. See ADR-010 and ADR-012.

---

## Overview

Phase 1 establishes the AI inference foundation: Ollama running natively on macOS for local LLM inference, Open WebUI as a browser-based chat interface, and OpenClaw on a separate Linux PC providing a Telegram bot front-end. All model inference runs on the Mac Studio; external services connect via LAN.

**Architecture:**

```
┌─────────────────────────────────────────────┐
│  Mac Studio (128GB Unified Memory)          │
│                                             │
│  ┌─────────────┐    ┌──────────────────┐    │
│  │   Ollama     │    │   Open WebUI     │    │
│  │  (native)    │◄───│  (OrbStack)      │    │
│  │  :11434      │    │  :3000           │    │
│  └──────┬───────┘    └──────────────────┘    │
│         │ LAN :11434                         │
└─────────┼────────────────────────────────────┘
          │
          ▼
┌─────────────────────┐       ┌───────────┐
│  Separate Linux PC  │       │ Telegram   │
│  ┌────────────┐     │◄─────►│ (webhook)  │
│  │  OpenClaw   │     │       └───────────┘
│  └────────────┘     │
└─────────────────────┘
```

---

## 1. Mac Studio Initial Setup

### Base System

1. **macOS setup wizard** — standard configuration, created admin account.
2. **FileVault** — enabled during setup. Critical note for headless operation: use `sudo fdesetup authrestart` for planned reboots. Without this, the Mac sits at the FileVault login screen after reboot, unreachable via SSH or Tailscale until someone types the password on a physical keyboard.
3. **Hostname** — set via System Settings → General → Sharing → Local Hostname.
4. **Energy settings** — disabled sleep, enabled "Start up automatically after a power failure."
5. **Automatic macOS updates** — disabled per ADR-011. Updates are applied manually during maintenance windows using `fdesetup authrestart`.

### Core Tools

All installed via [Homebrew](https://brew.sh/):

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

brew install --cask warp
brew install --cask orbstack        # see ADR-003
brew install --cask tailscale       # see ADR-004
brew install --cask stats
brew install ollama                 # binary only — lifecycle managed by user LaunchAgent, see ADR-010
```

---

## 2. Ollama Configuration

Ollama runs **natively on macOS** — not containerized — to access full unified memory and Metal GPU acceleration. See [ADR-001](../decisions/ADR-001-ollama-native-not-containerized.md).

Homebrew installs the `ollama` binary but does not manage its lifecycle in this setup. Lifecycle is owned by a user LaunchAgent at `~/Library/LaunchAgents/com.fitz.ollama.plist`. This approach is documented in [ADR-010](../decisions/ADR-010-ollama-launchagent.md).

> ⚠️ **DO NOT USE** `launchctl setenv OLLAMA_HOST ...` — this was the approach in the original setup and it failed after a reboot on April 11 (see [ADR-012](../decisions/ADR-012-april-11-reboot-incident-retrospective.md)). `launchctl setenv` values are session-scoped and cleared on reboot, leaving Ollama bound to localhost. The LaunchAgent approach below is the canonical method.

### Environment Variables (Baked Into the LaunchAgent)

All Ollama configuration lives in the plist's `EnvironmentVariables` block — no external state, no `launchctl setenv`.

| Variable | Value | Purpose |
|---|---|---|
| `OLLAMA_HOST` | `0.0.0.0` | Listen on all interfaces (required for LAN access from MacBook, OpenClaw) |
| `OLLAMA_NUM_PARALLEL` | `2` | Two simultaneous inference requests; further requests queue |
| `OLLAMA_KEEP_ALIVE` | `24h` | Keep model loaded for 24h to avoid reload latency between sessions |
| `OLLAMA_FLASH_ATTENTION` | `1` | Apple Silicon attention kernel acceleration (Homebrew default) |
| `OLLAMA_KV_CACHE_TYPE` | `q8_0` | Quantize KV cache to halve its memory footprint with minimal quality loss |

### Deploying the LaunchAgent

```bash
# Make sure Homebrew isn't also trying to manage Ollama
brew services stop ollama 2>/dev/null

# Write the plist
cat > ~/Library/LaunchAgents/com.fitz.ollama.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.fitz.ollama</string>
    <key>ProgramArguments</key>
    <array>
        <string>/opt/homebrew/opt/ollama/bin/ollama</string>
        <string>serve</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>OLLAMA_HOST</key><string>0.0.0.0</string>
        <key>OLLAMA_NUM_PARALLEL</key><string>2</string>
        <key>OLLAMA_KEEP_ALIVE</key><string>24h</string>
        <key>OLLAMA_FLASH_ATTENTION</key><string>1</string>
        <key>OLLAMA_KV_CACHE_TYPE</key><string>q8_0</string>
        <key>PATH</key><string>/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>LimitLoadToSessionType</key>
    <array>
        <string>Aqua</string><string>Background</string>
        <string>LoginWindow</string><string>StandardIO</string><string>System</string>
    </array>
    <key>WorkingDirectory</key><string>/opt/homebrew/var</string>
    <key>StandardOutPath</key><string>/opt/homebrew/var/log/ollama.log</string>
    <key>StandardErrorPath</key><string>/opt/homebrew/var/log/ollama.log</string>
</dict>
</plist>
PLIST

# Validate and load
plutil -lint ~/Library/LaunchAgents/com.fitz.ollama.plist
launchctl load ~/Library/LaunchAgents/com.fitz.ollama.plist
```

### Verification (Three Independent Signals)

```bash
# 1. launchd has it loaded with exit code 0
launchctl list | grep com.fitz.ollama

# 2. Bound to * (all interfaces), not localhost
lsof -i :11434
# Expected: ollama  <pid> fitz   3u  IPv6 ...  TCP *:11434 (LISTEN)

# 3. API responding with models
curl -s http://localhost:11434/api/tags | head -c 200
```

If step 2 shows `localhost:11434` instead of `*:11434`, the plist's env vars aren't being applied — check `plutil -lint` and `launchctl list` output.

### Maintenance

- **After `brew upgrade ollama`:** the binary is replaced but the running process still runs the old version. Refresh with:
  ```bash
  launchctl kickstart -k gui/$(id -u)/com.fitz.ollama
  ```
- **Full restart** (rare): `launchctl unload && launchctl load` with the plist path.
- **Rollback to Homebrew management** (not recommended): `launchctl unload ~/Library/LaunchAgents/com.fitz.ollama.plist && brew services start ollama`.

### Model Management

```bash
ollama pull qwen3.5:122b-a10b
ollama list
ollama ps                         # what's currently loaded in memory
ollama stop qwen3.5:122b-a10b     # unload (frees memory)
ollama run qwen3.5:9b "hello"     # quick test
```

**Only one model is loaded in memory at a time.** Requesting a different model triggers an unload/load cycle. With `OLLAMA_KEEP_ALIVE=24h`, the active model stays loaded across sessions.

### Model Roster

| Model | Role | Disk | Active | Notes |
|---|---|---|---|---|
| Qwen 3.5 122B-A10B | Primary (heavy tasks) | ~70GB | 10B (MoE) | Best quality; 262K context |
| Qwen 3.5 9B | Fast (Telegram) | ~6GB | 9B | Sub-60s for Telegram webhook |
| Qwen 2.5 72B | Fallback | ~41GB | 72B | If 3.5 has Ollama issues |
| Llama 4 Scout | Evaluation | ~67GB | TBD | Queued |
| Nemotron-Cascade-2 | Evaluation (coding) | ~18GB | 3B (MoE) | Queued |

See [ADR-002](../decisions/ADR-002-qwen-35-122b-primary-model.md). Ruled out: Llama 4 Maverick (~245GB), DeepSeek V3.2/V4, DeepSeek R1.

---

## 3. Open WebUI

```bash
docker run -d \
  --name open-webui \
  --restart unless-stopped \
  -p 3000:8080 \
  -e OLLAMA_BASE_URL=http://host.docker.internal:11434 \
  -v open-webui-data:/app/backend/data \
  ghcr.io/open-webui/open-webui:main
```

**Key detail:** `OLLAMA_BASE_URL` uses `host.docker.internal` to reach the native Ollama process from inside the container.

Access: `http://localhost:3000` locally, `http://<studio-ip>:3000` from LAN, `http://<tailscale-ip>:3000` remote.

---

## 4. OpenClaw & Telegram Bot

OpenClaw runs on a **separate Linux PC**. It connects to the Mac Studio's Ollama instance via LAN IP.

- Endpoint: `http://<mac-studio-ip>:11434/v1/` (OpenAI-compatible, **not** Ollama's `/api/`)
- Telegram bot token via BotFather, configured in OpenClaw.
- Telegram's ~60s webhook timeout requires the bot to use the 9B model — 122B first-token latency exceeds the window.

End-to-end flow:
```
User (Telegram) → webhook → OpenClaw (Linux PC)
    → Ollama /v1/chat/completions (Mac Studio) → response
    → OpenClaw → Telegram → User
```

---

## 5. Tailscale

```bash
tailscale up
tailscale ip -4   # 100.x.x.x, stable across reboots
```

All services then reachable via the `100.x.x.x` IP from any Tailscale-connected device. See [ADR-004](../decisions/ADR-004-tailscale-over-port-forwarding.md).

---

## Troubleshooting

### Ollama only listening on localhost after reboot

Symptom: `lsof -i :11434` shows `localhost:11434` instead of `*:11434`; LAN clients can't reach Ollama.

**This is the April 11 failure mode.** If you see this on a machine that was supposed to be running the LaunchAgent:
1. Confirm the plist exists: `ls -la ~/Library/LaunchAgents/com.fitz.ollama.plist`
2. Confirm it's loaded: `launchctl list | grep com.fitz.ollama`
3. If loaded but still localhost-only, inspect env: the plist's `EnvironmentVariables` block must contain `OLLAMA_HOST` with value `0.0.0.0`. Run `plutil -p ~/Library/LaunchAgents/com.fitz.ollama.plist` to dump it.
4. `launchctl unload && launchctl load` to reapply.

### Ollama not running at all

```bash
launchctl list | grep com.fitz.ollama
# If absent: launchctl load ~/Library/LaunchAgents/com.fitz.ollama.plist
# If present with non-zero exit code: check /opt/homebrew/var/log/ollama.log
```

### Model load fails / out of memory

```bash
ollama ps
ollama stop <current-model>
ollama run <new-model>
```

### Open WebUI can't reach Ollama

Verify `OLLAMA_BASE_URL=http://host.docker.internal:11434` in the container's env — **not** `localhost`.

### FileVault blocks headless reboot

```bash
sudo fdesetup authrestart
```
Always use this for operator-initiated reboots. ADR-011 eliminates unattended reboots as a category.

---

## Lessons Learned

1. **`launchctl setenv` is session-scoped and unsuitable for production Ollama config.** The original Phase 1 setup used it; it survived 12 days of uptime and failed on the first reboot. Replaced with a user LaunchAgent (ADR-010).
2. **Native Ollama is non-negotiable on Apple Silicon.** Containerized = no Metal, no full memory access, 5-10x slower.
3. **Model splitting by use case is essential.** One model can't serve both a 60-second webhook timeout and complex reasoning tasks.
4. **OpenClaw expects OpenAI API format** (`/v1/`), not Ollama's native `/api/`.
5. **FileVault + headless is solvable with `fdesetup authrestart`** — but requires operator-initiated reboots, which is now the policy (ADR-011).
