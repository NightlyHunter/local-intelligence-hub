# Phase 1: AI & OpenClaw — Setup Guide

> **Hardware:** Mac Studio, 128GB Unified Memory, 2TB Internal SSD
> **Completed:** March 30 – April 5, 2026

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
2. **FileVault** — enabled during setup. Critical note for headless operation: use `fdesetup authrestart` for planned reboots. Without this, the Mac sits at the FileVault login screen after reboot, unreachable via SSH or remote access until someone types the password on a physical keyboard.
3. **Hostname** — set via System Settings → General → Sharing → Local Hostname.
4. **Energy settings** — disabled sleep, enabled "Start up automatically after a power failure."

### Core Tools

All installed via [Homebrew](https://brew.sh/):

```bash
# Package manager
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Terminal
brew install --cask warp

# Container runtime (see ADR-003)
brew install --cask orbstack

# System monitoring (menu bar)
brew install --cask stats

# AI inference (see ADR-001)
brew install ollama
```

---

## 2. Ollama Configuration

Ollama runs **natively on macOS** — not containerized — to access full unified memory and Metal GPU acceleration. See [ADR-001](../decisions/ADR-001-ollama-native-not-containerized.md) for the full rationale.

### Environment Variables

Ollama runs as a macOS background service (LaunchAgent). It does **not** read shell profile exports (`~/.zshrc`, `~/.bash_profile`). Environment variables must be set via `launchctl setenv`:

```bash
# Listen on all interfaces (required for LAN access)
launchctl setenv OLLAMA_HOST 0.0.0.0

# Allow two simultaneous requests; extras queue (max 512)
launchctl setenv OLLAMA_NUM_PARALLEL 2

# Keep model loaded for 24 hours (avoids reload between sessions)
launchctl setenv OLLAMA_KEEP_ALIVE 24h

# Restart to pick up changes
brew services restart ollama
```

### Verify Binding

```bash
# Should show Ollama listening on *:11434 (all interfaces)
lsof -i :11434
```

If it shows `localhost:11434` or `127.0.0.1:11434`, the `OLLAMA_HOST` variable didn't take — re-run `launchctl setenv` and restart.

### Model Management

```bash
# Pull a model
ollama pull qwen3.5:122b-a10b

# List downloaded models
ollama list

# Check what's currently loaded in memory
ollama ps

# Unload current model (frees memory)
ollama stop qwen3.5:122b-a10b

# Quick test
ollama run qwen3.5:9b "Hello, what model are you?"
```

**Only one model is loaded in memory at a time.** Requesting a different model triggers an unload/load cycle. With `OLLAMA_KEEP_ALIVE=24h`, the active model stays loaded between sessions.

### Model Roster

| Model | Role | Disk Size | Active Params | Notes |
|---|---|---|---|---|
| Qwen 3.5 122B-A10B | Primary (heavy tasks) | ~70GB | 10B (MoE) | Best quality; 262K context |
| Qwen 3.5 9B | Fast (Telegram, routine) | ~6GB | 9B (dense) | Sub-60s for Telegram webhook |
| Qwen 2.5 72B | Fallback | ~41GB | 72B (dense) | Insurance if 3.5 has issues |
| Llama 4 Scout | Evaluation | ~67GB | TBD | Queued for comparison |
| Nemotron-Cascade-2 | Evaluation (coding) | ~18GB | 3B (MoE) | Queued for coding tasks |

See [ADR-002](../decisions/ADR-002-qwen-35-122b-primary-model.md) for model selection rationale.

**Ruled out:** Llama 4 Maverick (~245GB, exceeds 128GB RAM), DeepSeek V3.2/V4 (too large), DeepSeek R1 (outdated).

---

## 3. Open WebUI

Open WebUI provides a browser-based ChatGPT-style interface for interacting with Ollama models.

### Deployment

Running as an OrbStack container, port 3000:

```bash
docker run -d \
  --name open-webui \
  --restart always \
  -p 3000:8080 \
  -e OLLAMA_BASE_URL=http://host.docker.internal:11434 \
  -v open-webui-data:/app/backend/data \
  ghcr.io/open-webui/open-webui:main
```

**Key detail:** `OLLAMA_BASE_URL` uses `host.docker.internal` to reach the native Ollama process from inside the container. This is OrbStack's DNS name for the host machine.

### Access

- **Local (Mac Studio):** `http://localhost:3000`
- **LAN (MacBook):** `http://<mac-studio-ip>:3000`
- **Remote:** Same LAN URL, connected via UniFi Teleport (see ADR-004)

First visit requires creating an admin account. Model switching is available in the UI — select 9B for quick tasks, 122B for heavy work.

---

## 4. OpenClaw & Telegram Bot

OpenClaw runs on a **separate Linux PC**, not on the Mac Studio. It acts as an AI agent framework that connects to Ollama for inference and exposes a Telegram bot interface.

### Setup

1. OpenClaw installed on the Linux PC following its documentation.
2. Configured to point at the Mac Studio's Ollama instance via LAN IP:
   - Endpoint: `http://<mac-studio-ip>:11434/v1/` (OpenAI-compatible endpoint)
   - **Gotcha:** OpenClaw expects the `/v1/` API format (OpenAI-compatible), not Ollama's native `/api/` endpoint.
3. Telegram bot token generated via [BotFather](https://t.me/BotFather).
4. Bot token configured in OpenClaw.

### End-to-End Flow

```
User message (Telegram) → Telegram webhook → OpenClaw (Linux PC)
    → Ollama /v1/chat/completions (Mac Studio) → response
    → OpenClaw → Telegram → User
```

### Telegram-Specific Constraint

Telegram enforces a **~60 second webhook timeout**. Large models (122B) can exceed this on first-token latency, especially when cold-loading. The Telegram bot is configured to use the **9B model** exclusively. The 122B model is reserved for Open WebUI and CLI use where there's no timeout pressure.

---

## 5. Remote Access

Remote access to the hub is handled outside this phase and does not require any additional software on the Mac Studio.

### Current: UniFi Teleport (Operator Access)

The UDM provides **UniFi Teleport / Site Magic**, a relay-based remote access service built into UniFi OS. The operator connects from a MacBook or phone via the WiFiman or UniFi mobile app. Once connected, the device has LAN-equivalent access — all hub services are reachable at their LAN IPs:

- Ollama API: `http://<mac-studio-ip>:11434`
- Open WebUI: `http://<mac-studio-ip>:3000`
- Phase 2 services on their respective ports

Teleport solves the T-Mobile CGNAT problem (no public IP, no port forwarding possible) by using UniFi's relay infrastructure. The UDM establishes an outbound connection to UniFi's coordination backend; operator devices connect through that relay. No router configuration or public IP needed.

### Planned: Cloudflare Tunnel (Phase 5, Public Jellyfin)

For Phase 5, Cloudflare Tunnel will expose Jellyfin to friends/family via a public URL. `cloudflared` runs as a container on the Mac Studio, creates an outbound tunnel to Cloudflare's edge, and serves a single hostname (e.g., `jellyfin.<domain>`). Guests visit a URL — no VPN client install, no account creation. Not implemented yet.

### Evaluated and Deferred: Tailscale, Local DNS

Tailscale (mesh VPN) and local DNS were evaluated as additional infrastructure. Both are deferred pending a concrete triggering need — Tailscale if a device moves off the LAN or if granular per-device ACLs become necessary; local DNS if service discovery by name becomes preferable to LAN IPs. See [ADR-004](../decisions/ADR-004-remote-access.md) for the full decision and revisit conditions.

---

## Troubleshooting

### Ollama not accessible from LAN

```bash
# Check binding
lsof -i :11434
# Should show *:11434, not localhost:11434

# If wrong, re-set and restart
launchctl setenv OLLAMA_HOST 0.0.0.0
brew services restart ollama
```

### Model load fails / out of memory

```bash
# Check what's loaded
ollama ps

# Unload current model first
ollama stop <model-name>

# Then pull/run the new one
ollama run <new-model>
```

### Open WebUI can't reach Ollama

Verify `OLLAMA_BASE_URL` is set to `http://host.docker.internal:11434` (not `localhost`, which resolves inside the container's own network namespace).

### FileVault blocks headless reboot

```bash
# Use authrestart for planned reboots
sudo fdesetup authrestart
```

This caches the decryption key for one reboot cycle, allowing the Mac to boot past FileVault without physical keyboard input.

---

## Lessons Learned

1. **`launchctl setenv` is the only way** to pass environment variables to Ollama on macOS. Shell exports don't work — the background service doesn't source shell profiles.
2. **Native Ollama is non-negotiable on Apple Silicon.** Containerized = no Metal, no full memory access, 5-10x slower.
3. **Model splitting by use case** is essential. One model can't serve both a 60-second webhook timeout and complex reasoning tasks. Fast model for latency-sensitive interfaces, large model for quality-sensitive work.
4. **OpenClaw expects OpenAI API format** (`/v1/`), not Ollama's native `/api/` — easy to miss during initial setup.
5. **FileVault + headless is solvable** with `fdesetup authrestart`, but you have to remember to use it every time.
