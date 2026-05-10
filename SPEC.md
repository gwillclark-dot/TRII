# TRII Spec

## What TRII is

A harness for running long-lived agentic CLI sessions as chat-supervised workers. Each project is an independent process: a long-running CLI agent in tmux, listening on a chat channel, with state files on disk.

## Invariants

These are the parts of the architecture that don't change across profiles or backends:

1. **Per-project long-running CLI session** — one tmux session per project, supervised by launchd
2. **Chat channel as dispatch surface** — inbound prompts and outbound posts both flow through the channel; no separate file-queue
3. **State files on disk** — `CLAUDE.md` (or equivalent), `STATE.md`, `RADAR.md`, `NEXT_STEPS.md`, `DECISIONS.md`, `session-log/`
4. **Scaffold command** — `trii new <name>` for new projects (Phase 2)
5. **Watchdog + heartbeat** — tmux-scrape watchdog for blocking prompts and idle detection; periodic heartbeat to prevent token-idle staleness

## Variables

These are the adapter seams:

- **Agent CLI** — `claude --channels` (Claude Max) | `codex` | `gemini` | `goose` | `aider`
- **Chat platform** — Discord (v1) | Slack (v2)
- **Listener mode**:
  - `plugin` — the agent CLI handles the chat connection itself (Claude's `--channels` plugin)
  - `trii` — TRII provides a generic listener that tmux-injects prompts into the agent CLI (BYO-CLI case)

## Profiles

### Claude Max (v1, Phase 2)

`claude --channels --dangerously-skip-permissions` per project, with `DISCORD_STATE_DIR` env override per process. The Discord plugin is built into `claude`, so TRII does not provide a listener — it's a thin scaffold + supervisor.

Hard dependency on a Claude Max subscription (uses subscription OAuth, not `ANTHROPIC_API_KEY`).

### BYO-CLI (v2, deferred)

TRII provides a generic Discord listener that tmux-injects prompts into whichever agent CLI the operator runs. Allows codex, gemini, goose, aider, etc. without porting the channels plugin.

## Out of scope

- Local-model orchestration (was the pre-pivot focus; not the path to product-market fit)
- Multi-tenant isolation (each project is a process; sandboxing is the agent CLI's responsibility, not TRII's)
- Web/desktop UI (chat channel IS the UI)

## Hard rules

- **Headless-first.** No interactive prompts in any TRII script. Setup is scriptable end-to-end.
- **Per-project state.** No shared global mutable state across projects. Each project's tmux session, plist, and state dir are independent.
- **Channel is the audit trail.** All operator-visible activity flows through the channel; logs are secondary.
