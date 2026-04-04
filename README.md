# TRII

Portable local-model orchestrator. Same operating model as TRAX — autonomous project management with scheduled runs, dispatch tasks, and state tracking — but designed to run on a local model behind two thin adapters.

## Architecture

```
dispatch/ → trii-run.sh → run-agent.sh  → local model (NemoClaw/Ollama/llama.cpp)
                        → post-message.sh → messaging (Slack/stdout)
                        → project state files (STATE.md, RADAR.md, etc.)
```

All environment-specific details (model backend, messaging platform, channel IDs) live in `trii.conf` and `channels.json`. The orchestration scripts never call model or messaging APIs directly.

## Quick Start

```bash
# Guided setup — checks prerequisites, installs what's missing
bash setup.sh

# Or with no prompts:
bash setup.sh --non-interactive
```

## Smoke Test (no Slack needed)

```bash
# Test messaging adapter (stdout mode)
MESSAGE_BACKEND=stdout ./post-message.sh general "TRII online"

# Test agent adapter (requires Ollama + model)
./run-agent.sh "Reply with one sentence: setup ok"
```

## Manual Setup

If you prefer to set up step by step instead of using `setup.sh`:

### Prerequisites

- **Docker Desktop** or **Colima** (container runtime, must be running)
- **Xcode CLI tools** (macOS): `xcode-select --install`
- **Node.js 22.16+** and **npm 10+**
- **Ollama**: `brew install ollama` (or see [ollama.com](https://ollama.com))
- **Python 3.9+**
- **8GB RAM** minimum (16GB recommended — sandbox image is 2.4GB compressed)

### Install NemoClaw

```bash
curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash
source ~/.zshrc  # pick up new PATH entries
```

### Pull the model

```bash
ollama pull gemma4
```

### Create the sandbox

```bash
NEMOCLAW_PROVIDER=ollama \
  NEMOCLAW_MODEL=gemma4 \
  nemoclaw onboard --non-interactive
```

Or run `nemoclaw onboard` for the interactive wizard.

**Known gotchas:**
- Colima socket path changed in newer versions — verify with `colima status`
- OOM during sandbox creation (exit 137): create 4GB swap or increase Docker memory
- Post-reboot: restart Docker/Colima first, then `openshell sandbox list` to verify

### Create a Slack app

1. Go to [api.slack.com/apps](https://api.slack.com/apps) → Create New App
2. Add bot scopes: `chat:write`, `channels:read`, `channels:history`
3. Install to your workspace
4. Copy the **Bot User OAuth Token** (`xoxb-...`)

### Configure TRII

```bash
cp .env.example .env
# Edit .env with your Slack bot token

# Edit trii.conf — set MODEL_BACKEND, MODEL_NAME
# Edit channels.json — add your Slack channel IDs
```

### Verify

```bash
# Test messaging (with real Slack)
./post-message.sh general "TRII online"

# Test agent
./run-agent.sh "Say hello"

# Test full run
bash trii-run.sh
```

### Schedule (optional)

Edit `com.trii.run.plist` — replace `/CHANGE_ME/TRII` with your actual path, then:

```bash
cp com.trii.run.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.trii.run.plist
```

## Adding Projects

1. Create a subdirectory (or clone a repo into TRII)
2. Bootstrap with templates: `cp templates/*.md your-project/`
3. Add to `RADAR.md`
4. Add a channel to `channels.json`
5. Add the project name to the `PROJECTS` array in `trii-run.sh`

## Dispatch

Write a JSON file to `dispatch/` to trigger an on-demand task:

```json
{
  "project": "my-project",
  "task": "Fix the auth bug in login.py",
  "channel": "general"
}
```

The dispatch watcher picks it up on the next run (or run `bash dispatch-watcher.sh` manually).

## Adapters

### `run-agent.sh`

Executes a prompt with the configured model backend. Supports:
- `nemoclaw` — OpenClaw agent inside NemoClaw sandbox
- `ollama` — Direct Ollama CLI
- `llamacpp` — llama.cpp server

Fails fast with clear messages if required binaries are missing.

### `post-message.sh`

Sends a message to the configured messaging backend. Supports:
- `slack` — Slack `chat.postMessage` API (validates response)
- `stdout` — Print to terminal (for testing)

Validates delivery end-to-end: curl errors, HTTP status, Slack `ok` field.

### `resolve-project.sh`

Shared helper sourced by both `trii-run.sh` and `dispatch-watcher.sh` to map project names to directories. Single source of truth — no duplicated case blocks.

## File Structure

```
TRII/
├── setup.sh               # One-time guided bootstrap
├── trii.conf              # All configuration
├── channels.json          # Channel map (name → ID)
├── .env.example           # Token template
├── run-agent.sh           # Model adapter
├── post-message.sh        # Messaging adapter
├── resolve-project.sh     # Project → directory resolver
├── trii-run.sh            # Main orchestrator
├── dispatch-watcher.sh    # Dispatch handler
├── CLAUDE.md              # Agent identity
├── SPEC.md                # Operating spec
├── STATE.md               # Current state
├── RADAR.md               # Project portfolio
├── INBOX.md               # Escalation queue
├── session-log/           # Run history
├── dispatch/              # Incoming tasks
├── templates/             # Project bootstrap files
└── com.trii.run.plist     # launchd schedule template
```
