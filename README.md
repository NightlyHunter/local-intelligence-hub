# 2026 Local Intelligence Hub

Self-hosted AI inference, media streaming, and home automation stack built on a Mac Studio with 128GB unified memory. Documented with Architecture Decision Records.

## What Is This?

A five-phase personal infrastructure project that turns a Mac Studio into a local-first intelligence hub — from running LLMs to streaming media to automating life admin. Every architectural decision is documented with ADRs to capture the *why*, not just the *how*.

## Architecture

| Layer | Stack |
|---|---|
| **AI Inference** | Ollama (native, Metal-accelerated) → Qwen 3.5 122B / 9B |
| **AI Agent** | OpenClaw (separate Linux PC) → Telegram bot |
| **Chat UI** | Open WebUI |
| **Media** | Prowlarr → Radarr / Sonarr / Lidarr → qBittorrent (behind gluetun VPN) → Jellyfin |
| **Documents** | Paperless-ngx (OCR + full-text search) |
| **Budget** | Actual Budget |
| **Automation** | n8n (tiered rollout) |
| **Remote Access** | Tailscale |
| **Containers** | OrbStack |

## Phases

| # | Phase | Status |
|---|---|---|
| 1 | AI & OpenClaw (The Brain) | ✅ Core complete |
| 2 | Media & Streaming (The Arrs) | 🔧 In progress |
| 3 | Life Admin & Budgeting (The Vault) | 🔜 July 2026 |
| 4 | Automation (The Glue) | 🔜 August 2026 |
| 5 | Remote Sharing (The Open Door) | 🔜 November 2026 |

## Architecture Decision Records

| ADR | Decision |
|---|---|
| [ADR-001](docs/decisions/ADR-001.md) | Why Ollama native vs. containerized |
| [ADR-002](docs/decisions/ADR-002.md) | Why Qwen 3.5 122B-A10B as primary model |
| [ADR-003](docs/decisions/ADR-003.md) | Why OrbStack over Docker Desktop |
| [ADR-004](docs/decisions/ADR-004.md) | Why Tailscale over traditional VPN |
| [ADR-005](docs/decisions/ADR-005.md) | Why external SSD → UniFi NAS migration path |
| [ADR-006](docs/decisions/ADR-006.md) | Why tiered automation rollout |
| [ADR-007](docs/decisions/ADR-007.md) | Why Jellyseerr for non-English title discovery |
| [ADR-008](docs/decisions/ADR-008.md) | Why gluetun VPN kill switch for torrent traffic |
| [ADR-009](docs/decisions/ADR-009.md) | Why Watchtower for automated container updates |

## Repo Structure

```
local-intelligence-hub/
├── README.md
├── docker-compose.yml           # All containerized services
├── .env.example                 # Template for secrets
├── docs/
│   ├── phase-1-ai/              # Ollama, OpenClaw, Telegram bot setup
│   ├── phase-2-media/           # Arr stack, Jellyfin, storage strategy
│   ├── phase-3-vault/           # Paperless-ngx, Actual Budget
│   ├── phase-4-automation/      # n8n workflows
│   ├── phase-5-sharing/         # Tailscale remote access
│   └── decisions/               # Architecture Decision Records
├── scripts/                     # Backup & maintenance scripts
└── diagrams/                    # Architecture & data flow visuals
```
## Hardware

- **Mac Studio** — Apple M-series, 128GB Unified Memory, 2TB Internal SSD
- **1TB Samsung T7 External SSD** — active media library (pre-NAS)
- **UniFi UNAS-4** (arriving September 2026) — 2×8TB IronWolf, RAID 1

## Setup
```bash
# 1. Clone
git clone https://github.com/YOUR_USERNAME/local-intelligence-hub.git
cd local-intelligence-hub

# 2. Create .env from template
cp .env.example .env
# Edit .env with your credentials

# 3. Start services
docker compose up -d
```

> ⚠️ This is a personal home lab — configs are tuned for my hardware and network. Use the ADRs and docs for the reasoning; adapt the specifics to your setup.

## License

MIT
