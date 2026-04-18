# Blueprint v4 — Amendments (April 14, 2026)

> Apply these changes to `2026_Local_Intelligence_Hub_Blueprint_v3.md` and bump version to v4.
>
> **Theme of this revision:** OpenClaw is no longer a Phase 1 component. It's an architectural pillar running in parallel with all phases, with its own scope, roadmap, and documentation subtree. This amendment reflects that reframing.

---

## 1. Version header

Change:

> Blueprint v3

to:

> Blueprint v4 — adds OpenClaw as an architectural pillar (previously scoped under Phase 1)

---

## 2. Replace the "Phase 1: AI & OpenClaw (The Brain)" section title with:

> Phase 1: AI Inference (The Brain)

And remove all OpenClaw-specific content from that section. Phase 1 now scopes only to:
- Ollama native on macOS (ADR-001, ADR-010)
- Primary + fallback model roster (ADR-002)
- Open WebUI as the browser interface
- LAN access; remote via UniFi Teleport (ADR-004)

Leave a single forward pointer at the end of Phase 1:

> **Agent runtime:** OpenClaw, which connects to this inference layer, is documented separately as an architectural pillar. See `openclaw/architecture.md`.

---

## 3. Add a new top-level section after all phase sections, before "Backup Strategy":

```markdown
## 🤖 OpenClaw — The Agent Runtime Layer

**Not a phase.** OpenClaw is the component that turns Ollama (an inference endpoint) into an
agent that takes actions in the world. It evolves in parallel with every phase: Phase 1 gave
it a Telegram front-end, Phase 2 gave it targets to automate against, Phase 3 gave it documents
to manipulate, Phase 4 (n8n) will either consume it or overlap with it. Treating it as a
phase-scoped deliverable undersells both its scope and its dependency fan-out.

**Runs on:** Separate Linux PC, connected to Mac Studio's Ollama over LAN.

**Exposes via:** Telegram bot (primary), future interfaces TBD.

**Skill categories** (each documented in `openclaw/skills/`):
1. Browser automation — stealth-patched Playwright, form filling, human-in-the-loop captcha
2. Document creation — PDF / DOCX / Markdown output, Paperless-ngx integration
3. System interaction — files, processes, Docker socket
4. Script execution — bash and Python, sandboxed
5. Knowledge base / RAG querying — backend TBD (Open WebUI RAG vs. ChromaDB vs. KB-Self-Hosting-Kit)
6. Telegram I/O — human-in-the-loop pattern, notifications, timeout-aware task routing

**What OpenClaw is not:**
- Not a replacement for Phase 4 n8n. OpenClaw handles interactive/conversational agent tasks
  ("do this thing for me right now"). n8n handles scheduled/event-driven workflows
  ("every morning at 7am, do this sequence"). Overlap exists; primary use cases differ.
- Not a general MCP server host. If MCP integration becomes desirable, that's a separate
  component with its own ADR.
- Not a multi-user system. Single-operator (Dmytro) by design.

**Cross-cutting concerns** (each will be resolved by an ADR in `openclaw/decisions/`):
- Skill source verification (ClawHavoc typosquatting risk — verification standard required)
- Model routing: which tasks go to 9B (Telegram's 60s budget) vs. 122B (tool-call reliability
  and error recovery)
- Human-in-the-loop: uniform "pause and ask Dmytro" API across all skills
- Permission model: declarative per-skill capability boundaries
- Observability: structured logging of every skill invocation for later audit

**Key constraints inherited from the rest of the stack:**
- Telegram's ~60s webhook timeout forces Telegram-invoked tasks onto the 9B model
- Browser automation must NOT route through gluetun (datacenter IP = constant bot challenges)
- 122B is the default for any task involving tool calls with structured output; 9B is the
  exception, not the rule

**Documentation lives at:** `openclaw/` subtree in the `local-intelligence-hub` repo.
See `openclaw/README.md` as entry point.
```

---

## 4. In the "Documentation (The Portfolio)" section, extend the ADR list:

Add a subsection break after ADR-012:

```markdown
### OpenClaw ADRs (OC-series)

- **ADR-OC-001:** Skill source verification standard
- **ADR-OC-002:** Human-in-the-loop pattern (uniform API across skills)
- **ADR-OC-003:** Model routing — 9B fast path vs. 122B default
- **ADR-OC-004:** Skill permission model
- **ADR-OC-005:** Observability — skill invocation logging

Additional ADRs will be written per skill as implementation decisions surface
(e.g., script execution sandboxing approach, knowledge-base backend choice).
```

---

## 4a. Rewrite the remote access references throughout the blueprint

**ADR-004 has been rewritten.** The original ADR-004 proposed Tailscale as the sole remote access method. Tailscale was never deployed. The rewritten ADR-004 documents what's actually in place and what's planned.

Wherever the blueprint references Tailscale as a deployed tool, remote access via `100.x.x.x` IPs, or `<tailscale-ip>`, replace with the actual state:

```markdown
## 🌐 Remote Access & Networking

**Current state:** All hub services are LAN-only. Remote operator access uses **UniFi Teleport /
Site Magic** — the relay-based VPN built into UniFi OS on the UDM. Teleport solves T-Mobile's
CGNAT (no public IP) by relaying through UniFi's coordination backend. When connected, the
operator has LAN-equivalent access and reaches services at their LAN IPs.

No additional software is installed on the Mac Studio or Linux PC for remote access.

**Planned (Phase 5):** **Cloudflare Tunnel** will expose Jellyfin to friends/family via a public
URL. `cloudflared` runs as a container, creates an outbound tunnel to Cloudflare's edge, and
serves a single hostname. Guests visit a link — no VPN client, no account creation.

**Evaluated and deferred:** **Tailscale** (mesh VPN) and **local DNS** (service discovery by name
instead of IP) were evaluated. Both are deferred pending concrete triggering needs:
- Tailscale: if a device moves off the LAN, if granular per-device ACLs become necessary,
  or if MagicDNS quality-of-life justifies the new dependency.
- Local DNS: if managing services by LAN IP becomes unwieldy.
- Cloudflare Tunnel is the first networking feature to implement; Tailscale and local DNS
  are subsequent considerations.

See ADR-004 (rewritten April 14, 2026) for the full decision.
```

Also update the ADR list in the Documentation section — ADR-004's title changes:

> - **ADR-004:** Remote access — UniFi Teleport primary, Cloudflare Tunnel planned, Tailscale deferred (rewritten from original Tailscale proposal)

---

## 5. Update the architecture diagram block

Wherever the blueprint shows the system architecture, add OpenClaw as a first-class box, not a sub-element of Phase 1. Suggested ASCII:

```
┌─────────────────────────────────────────────────────────────┐
│                    Mac Studio (Phase 1)                      │
│    Ollama ────── Open WebUI                                  │
└───────▲─────────────────────────────────────────────────────┘
        │ LAN :11434
        │
┌───────┴──────────────┐        ┌──────────────────────────┐
│  Linux PC            │        │ Mac Studio (Phases 2-3)   │
│  ┌────────────────┐  │        │  Media stack, Paperless,  │
│  │   OpenClaw     │◄─┼────────┤  Actual Budget            │
│  │ (agent runtime)│  │ tools  │                           │
│  │                │  │        └──────────────────────────┘
│  │   Skills:      │  │
│  │   ├ browser    │  │        ┌──────────────────────────┐
│  │   ├ documents  │◄─┼────────┤ Telegram (webhook I/O)    │
│  │   ├ system     │  │        └──────────────────────────┘
│  │   ├ scripts    │  │
│  │   ├ knowledge  │  │
│  │   └ telegram   │  │
│  └────────────────┘  │
└──────────────────────┘
```

---

## 6. In the timeline/roadmap table

Add a new row (or column, depending on blueprint's current format) for OpenClaw, with entries flowing across all time periods rather than clustered in a single phase:

| Period | OpenClaw milestone |
|---|---|
| April 2026 | Base install + Telegram bot working; skill catalog planned |
| May 2026 | First skill ADRs written (OC-001 through OC-005); browser automation skill installed |
| June 2026 | Document + system + script execution skills online |
| July–August 2026 | Knowledge base skill (pending backend decision in Phase 4 planning) |
| September 2026 | NAS arrival — re-evaluate whether any OpenClaw skills need to move |
| Q4 2026 | Phase 4 n8n begins — OpenClaw/n8n integration pattern decided |

Also add a **Networking** row to the timeline:

| Period | Networking milestone |
|---|---|
| Current | UniFi Teleport for operator remote access; all services LAN-only |
| Phase 5 | Cloudflare Tunnel for public Jellyfin |
| Post-Phase 5 | Evaluate Tailscale and local DNS based on triggering needs (see ADR-004) |

---

## 7. Progress tracker

OpenClaw has its own progress tracker as an **internal document** (not pushed to GitHub). It lives alongside the hub's progress tracker in the operator's local working files, not in the repo. See `openclaw-progress-tracker.md`.

The public-facing `openclaw/README.md` references current status at a high level but leaves in-flight operational detail to the internal tracker.

---

## 8. Notes for the repo structure

The `openclaw/` directory in the repo is a first-class subtree, not a nested project:

```
local-intelligence-hub/
├── README.md
├── docker-compose.yml (sanitized)
├── decisions/                  # Hub-level ADRs (001–012)
├── phase-1-ai-setup.md
├── phase-2-media-setup.md
├── phase-3-*.md
├── openclaw/                   # ← new subtree
│   ├── README.md
│   ├── architecture.md
│   ├── decisions/              # OC-series ADRs
│   ├── skills/
│   ├── setup/
│   └── runbooks/
└── blueprint.md (v4)
```

The hub's top-level `decisions/` directory and `openclaw/decisions/` are separate ADR namespaces. Hub ADRs are numbered `ADR-NNN`; OpenClaw ADRs are `ADR-OC-NNN`. Cross-references allowed and encouraged.
