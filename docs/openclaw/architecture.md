# OpenClaw Architecture

> **Status:** Foundation document. Cross-cutting ADRs referenced here are drafted separately in `decisions/`. Individual skill docs live in `skills/`.
> **Version:** 1.0 (April 14, 2026)

---

## 1. The agent runtime framing

An LLM by itself is a text-in, text-out function. It can reason about action but cannot act. To turn reasoning into action, three things are needed:

1. **An inference endpoint** — something that runs the model and returns token streams. (Ollama, in this stack.)
2. **A tool execution layer** — something that parses structured tool calls from the model's output, executes real operations, and feeds results back as new context. (OpenClaw.)
3. **A skill catalog** — the actual library of tools the model can invoke: browser control, file I/O, script execution, network calls, and so on. (The `skills/` subtree.)

OpenClaw is #2. It's the orchestrator, not the intelligence and not the capability set.

Separating these three layers is deliberate. It means:
- Swapping models is cheap (Qwen 3.5 today, something else tomorrow — Ollama abstracts it).
- Adding a capability means adding a skill, not rebuilding the agent.
- Observability and permission enforcement happen at one chokepoint (OpenClaw), not scattered across skills.

## 2. What a "skill" is, formally

In this architecture, a **skill** is a named capability bundle with five required properties:

1. **Tool surface** — one or more tools exposed to the model, each with a typed JSON schema (name, description, parameters, return shape).
2. **Source verification record** — documentation of where the skill came from, who publishes it, what version is pinned, and what was reviewed before trust was extended. (Enforced by ADR-OC-001.)
3. **Permission declaration** — explicit statement of what the skill is allowed to do: which filesystem paths it can touch, which network destinations it can reach, which host resources it can consume. (Enforced by ADR-OC-004.)
4. **Observability hooks** — every tool invocation produces a structured log entry covering inputs, outputs, duration, and outcome. (Enforced by ADR-OC-005.)
5. **Failure semantics** — documented behavior when things go wrong: does the skill retry, fail loud, pause for human input, or degrade gracefully? (Addressed per skill, with uniform HITL API from ADR-OC-002.)

This is a stricter definition than OpenClaw upstream uses. The stricter definition is deliberate — it makes the portfolio angle meaningful ("here's how I made an agent auditable and constrained") rather than just cataloging capabilities.

Skills that can't meet all five requirements don't get installed. This is the simplest enforcement mechanism and the one that scales.

## 3. Skill categories

Six categories, scoped deliberately. Each has a dedicated doc in `skills/`.

### 3.1 Browser automation

Headless (or headful) Chromium driven by Playwright with stealth patching. Exposes navigation, DOM interaction, form filling, screenshot capture, and human-in-the-loop fallback for captchas and interactive challenges.

**Why it's here:** enables the widest category of automation — anything that runs in a web browser is reachable. Also the most operationally complex skill, which is why it gets its own reference doc (already written, pending relocation into `skills/browser-automation.md`).

**Key constraints:**
- Must use residential IP (not gluetun/ProtonVPN — datacenter IPs get flagged)
- 122B only — 9B can't sustain multi-step browser workflows reliably
- Persistent user-data directory is infrastructure, not cache — treat accordingly

### 3.2 Document creation

Producing PDF, DOCX, and Markdown outputs, and inserting them into the appropriate downstream system (Paperless-ngx for archiving, local filesystem, Telegram for delivery).

**Why it's here:** a lot of interesting automation output is a document — an invoice summary, a meeting note, a filled form. Without this skill, the agent can only produce chat messages.

**Key decisions deferred:**
- Rendering engine: system tools (pandoc, wkhtmltopdf) vs. library-based (Python-docx, ReportLab). To be decided when the skill is built.
- Whether output lands in Paperless-ngx automatically or via an intermediate review step.

### 3.3 System interaction

File operations, process management, Docker socket access. Let the agent list directories, read/write files in permitted locations, inspect running containers, restart services when explicitly authorized.

**Why it's here:** most useful home-lab automations need to touch the host somehow — check disk usage, restart a stuck container, tail a log. Without this, the agent is blind to the system it's supposed to be helping with.

**Primary security concern:** this is where the permission model has teeth. A "list files" tool and a "delete files" tool are categorically different; they cannot share the same permission envelope. ADR-OC-004 addresses this.

### 3.4 Script execution

Running bash and Python scripts. Either scripts written by the agent on the fly, or pre-registered scripts the agent can invoke by name.

**Why it's here:** the most general-purpose capability. Anything the agent can't do through a dedicated skill can usually be done through a script.

**Primary security concern:** arbitrary code execution on the Linux PC. This absolutely requires sandboxing — the decision between Docker-in-Docker, `nsjail`, `firejail`, or something else is a pending ADR to be written when this skill is built. Default posture until then: no arbitrary script execution, only pre-registered whitelist.

### 3.5 Knowledge base / RAG

Querying a vector store or document index for context the agent doesn't have in its training data — setup docs, ADRs, past conversations, ingested reference material.

**Why it's here:** the agent becomes dramatically more useful when it can reference "how did I configure this last time" or "what does the blueprint say about X." Without it, the agent either hallucinates or asks for context on every turn.

**Backend undecided.** Three candidates:
- **Open WebUI's built-in RAG** — simplest, shares infrastructure with the chat interface
- **Standalone ChromaDB** — more control, reusable across agents and interfaces
- **Knowledge-Base-Self-Hosting-Kit** — most featured, highest operational complexity

Decision deferred until Phase 4 planning. Until then, the skill doc captures what the tool surface should look like regardless of backend.

### 3.6 Telegram I/O

Not just "send and receive messages" — this is the skill that implements the human-in-the-loop (HITL) pattern other skills depend on. When browser automation hits a captcha, when system interaction wants confirmation before deleting files, when script execution needs approval before running — all of these go through Telegram I/O's HITL API.

**Why it's foundational:** half the skills above depend on this one for their failure-semantics contract.

**Key constraint:** Telegram's ~60 second webhook timeout. Any tool invoked directly from a Telegram message must complete within that window or use the async pattern (immediate ack, followup message when done). This is documented in detail in `skills/telegram-io.md`.

## 4. Dependency graph

```
                           ┌──────────────┐
                           │   Telegram   │
                           └──────┬───────┘
                                  │
                          ┌───────▼────────┐
                          │ Telegram I/O   │ (skill)
                          │ — HITL API     │
                          └───────┬────────┘
                                  │ used by other skills
                                  ▼
┌─────────────────────────────────────────────────────────────┐
│                        OpenClaw                              │
│                  (agent runtime layer)                       │
│                                                              │
│   Skills:  browser  docs  system  scripts  KB  telegram     │
└───────────────┬───────────────────────────────────┬─────────┘
                │                                   │
        ┌───────▼────────┐                 ┌────────▼─────────┐
        │   Ollama       │                 │  Target systems  │
        │   (Mac Studio) │                 │  — media stack   │
        │   /v1/ API     │                 │  — Paperless-ngx │
        └────────────────┘                 │  — Actual Budget │
                                           │  — file system   │
                                           │  — web (browser) │
                                           └──────────────────┘
```

**Upward dependencies** (what OpenClaw needs to function):
- Ollama reachable at the Mac Studio's LAN IP on port 11434
- LAN connectivity between Linux PC and Mac Studio (both on same subnet behind the UDM)
- Linux PC powered and reachable
- Telegram webhook registered and DNS resolvable (for bot I/O)

**Downward dependencies** (what depends on OpenClaw):
- Every user-facing Telegram interaction
- Any future automation that requires an LLM to take actions rather than produce text
- Phase 4 n8n workflows that need agent-style reasoning mid-flow (specific integration pattern TBD)

## 5. Cross-cutting concerns

Each of these has a dedicated ADR being drafted. They're called out here because every skill inherits from all five, so the standards have to be set before skills are installed in earnest.

### 5.1 Skill source verification (ADR-OC-001)

**Problem:** the ClawHavoc typosquatting campaign means "install this OpenClaw skill" is not a trust-neutral operation. A malicious skill is arbitrary code execution on the Linux PC.

**Direction:** verification checklist before any skill is installed — publisher identity, GitHub repo history, commit velocity and reviewer quality, review of the tool surface to confirm nothing is exposed that shouldn't be, pinned version rather than `latest`, and a local audit record kept in `skills/<name>.md` under a "Provenance" heading.

### 5.2 Human-in-the-loop (ADR-OC-002)

**Problem:** multiple skills need "pause the agent, ask Dmytro, resume with the answer." Captcha in browser automation, deletion confirmation in system interaction, script approval in script execution. Re-implementing this per skill is a recipe for divergence.

**Direction:** uniform HITL API provided by the Telegram I/O skill. Other skills call `hitl.ask(prompt, options=[...])` or `hitl.confirm(action)` and block until a Telegram response arrives. Defines timeouts, fallback behavior, and logging.

### 5.3 Model routing (ADR-OC-003)

**Problem:** the stack has two primary models (122B for quality/tool reliability, 9B for Telegram's 60s budget). Which model handles which request is currently implicit and varies by interface.

**Direction:** explicit routing policy driven by task properties, not interface. Tool-calling tasks default to 122B. Purely conversational tasks can use 9B. Telegram-originated tasks that need 122B use the async pattern (ack immediately, deliver result in a followup message). Rules documented once, referenced by every skill.

### 5.4 Permission model (ADR-OC-004)

**Problem:** "system interaction" as a skill label hides huge variance in blast radius. `ls` is safe; `rm -rf` isn't. A single skill with no internal permission gradient is either too permissive or too restrictive.

**Direction:** declarative permissions per tool (not per skill), with a three-tier model: `read` (always allowed within scope), `mutate` (allowed but logged prominently), `destructive` (HITL confirmation required). Each tool's tier is declared in its schema, enforced by the runtime before execution.

### 5.5 Observability (ADR-OC-005)

**Problem:** when an agent does something surprising or wrong, the only way to debug it is a record of what it did. Ad-hoc logging produces inconsistent records that are useless weeks later.

**Direction:** structured JSON logs for every tool invocation. Fields: timestamp, skill name, tool name, inputs (truncated/redacted per sensitivity), outputs (same), duration, outcome (success/failure/HITL), and caller context (which Telegram user, which chat, which model was routing). Log rotation and a simple query tool to answer "what did the agent do last Tuesday."

## 6. Inherited constraints

These come from decisions elsewhere in the stack but shape every skill:

- **Telegram 60s webhook timeout** — limits synchronous Telegram-invoked tasks to 9B or forces async pattern.
- **Residential IP for browser automation** — gluetun is off-limits for the browser skill's network path.
- **122B is the default for tool use** — 9B's tool-call JSON reliability is materially worse; it's the exception, not the default.
- **Single-operator home lab** — no multi-user concerns, but also no "someone else will notice the outage" — failures need to be loud enough for one person to catch.
- **Evenings and weekends only** — build scope per skill has to fit a few focused sessions, not a sustained sprint.

## 7. What's deliberately not in scope

Listed here so discussions don't have to re-litigate these:

- **Multi-agent orchestration.** One OpenClaw instance, one operator. If multi-agent becomes interesting later, that's a new component.
- **Agent-to-agent protocols (A2A, etc.).** OpenClaw is the agent. Other things call OpenClaw; OpenClaw doesn't federate with peers.
- **Local training, fine-tuning, or LoRA adaptation.** Ollama runs what Ollama runs. Training is a different problem with different infrastructure.
- **Voice I/O.** Telegram text in, text out. No speech-to-text, no text-to-speech.
- **Vision.** Qwen 3.5 is not multimodal in the sense required for vision-based agents. Screenshot-to-action flows are out until a multimodal model joins the stack.

## 8. Milestone sequence

Not a commitment, just a reasonable order:

1. Telegram diagnostic (unblock current broken state from April 11 fallout)
2. Cross-cutting ADRs (OC-001 through OC-005) drafted
3. Browser automation skill: relocate stealth doc, install Playwright-based skill, verify source, first end-to-end automation
4. Telegram I/O skill formalized with HITL API
5. System interaction + script execution skills (paired — they share the security thinking)
6. Document creation skill
7. Knowledge base skill (pending backend decision from Phase 4 planning)

At any point along this sequence, the built skills should be fully documented, observable, and permission-scoped. No "we'll add the ADRs later." The discipline is the deliverable.

## 9. Open questions to resolve as we go

- Does OpenClaw run as a systemd service on the Linux PC, or launched per-task? Leaning toward systemd with per-session isolation for state.
- How are skills versioned and updated? Watchtower-equivalent for skills, or manual updates with a changelog?
- Where does OpenClaw's own configuration and state live? (Separate from skill configs?) Backup strategy?
- How does OpenClaw interact with the knowledge base skill for self-reference — can it query its own ADRs to reason about its own permissions? (Probably yes, but the recursion has interesting edges.)

These surface into ADRs as answers firm up.
