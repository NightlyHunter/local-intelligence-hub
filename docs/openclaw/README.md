# OpenClaw

The agent runtime layer of the Local Intelligence Hub.

## What this is

Ollama (on the Mac Studio) handles inference. OpenClaw (on a separate Linux PC) turns that inference into action — it's the orchestrator that lets the model browse the web, fill forms, manipulate documents, run scripts, query knowledge bases, and send Telegram messages.

If Ollama is the brain, OpenClaw is the hands. Ollama emits tool calls as structured text; OpenClaw parses them, executes the real actions, and feeds results back.

## Why this is its own subtree

OpenClaw was originally scoped under Phase 1 as "the Telegram bot front-end." That framing stopped holding as soon as skill expansion entered the plan. OpenClaw now spans all phases: it automates against the media stack (Phase 2), manipulates documents in Paperless-ngx (Phase 3), and will either integrate with or overlap n8n (Phase 4). It's an architectural pillar, not a phase deliverable.

See `../blueprint.md` (v4) for the full reframing.

## Current status

**Foundation:** Complete.
- Installed on Linux PC
- Connected to Ollama over LAN (OpenAI-compatible `/v1/` endpoint)
- Telegram bot integrated; end-to-end chain confirmed

**Skill expansion:** In planning. See `architecture.md` for the skill roster and `decisions/` for cross-cutting ADRs being drafted.

**Active open items:**
- Telegram diagnostic pending from April 11 fallout check (may still be session-scoped issue)
- Cross-cutting ADRs (OC-001 through OC-005) to be written before major skill installation
- Browser automation stealth reference doc exists at the repo root; needs relocation to `skills/browser-automation.md` and extension with form-filling + HITL patterns

## Directory structure

```
openclaw/
├── README.md                       # this file
├── architecture.md                 # agent runtime framing, skill definition, dependencies
├── decisions/                      # OC-series ADRs
│   ├── ADR-OC-001-skill-source-verification.md
│   ├── ADR-OC-002-human-in-the-loop.md
│   ├── ADR-OC-003-model-routing.md
│   ├── ADR-OC-004-permission-model.md
│   └── ADR-OC-005-observability.md
├── skills/                         # per-skill docs
│   ├── browser-automation.md
│   ├── document-creation.md
│   ├── system-interaction.md
│   ├── script-execution.md
│   ├── knowledge-base.md
│   └── telegram-io.md
├── setup/
│   ├── openclaw-installation.md
│   ├── skills-installation.md
│   └── troubleshooting.md
└── runbooks/
    ├── captcha-fallback.md
    ├── skill-failure-recovery.md
    └── model-switching.md
```

Most of these are stubs at time of writing. `architecture.md` is the substantive companion to this README.

## Relationship to the rest of the hub

**Depends on:**
- **Ollama (Phase 1, Mac Studio)** — inference endpoint via `http://<mac-studio>:11434/v1/`
- **LAN connectivity** — Linux PC and Mac Studio on the same subnet behind the UDM
- **Linux PC** — OpenClaw's host; must stay reachable and powered

**Depended on by:**
- **Telegram I/O** — user-facing front-end for most agent interactions
- **Future automations** — anything that needs an LLM to take actions, not just produce text

**Parallel to:**
- **n8n (Phase 4)** — different primary use case (scheduled workflows vs. interactive agent tasks), some overlap. Integration pattern decided when Phase 4 planning begins.

## How to use this documentation

- Start with `architecture.md` if you're trying to understand how OpenClaw works conceptually
- Go to `skills/<name>.md` if you're working on a specific capability
- Go to `decisions/` if you're trying to understand *why* something is the way it is
- Go to `runbooks/` if something is broken

## Non-goals

Documented explicitly so scope doesn't creep:

- **Not a replacement for n8n.** Scheduled/triggered workflows go to n8n when it's built. OpenClaw is for interactive, conversational, or ad-hoc agent tasks.
- **Not a general MCP server host.** If MCP integration becomes useful later, that's a separate architectural decision.
- **Not a multi-user system.** Single-operator by design. No user roles, no per-user permissions.
- **Not a production service.** Home lab reliability target: "works when I need it, fixable in an evening when it breaks." No 9s of uptime.
