# TRII

Portable local-model orchestrator. Same operating model as TRAX — autonomous project management with scheduled runs, dispatch tasks, and state tracking — but designed to run on a local model behind two thin adapters.

## Architecture

```
dispatch/ → trii-run.sh → run-agent.sh  → local model (NemoClaw/Ollama/llama.cpp)
                        → post-message.sh → messaging (Slack/stdout)
                        → project state files (STATE.md, RADAR.md, etc.)
```

All environment-specific details (model backend, messaging platform, channel IDs) live in `trii.conf` and `channels.json`. The orchestration scripts never call model or messaging APIs directly.

## Setup

### 1. Prerequisites

- **Docker** or **Colima** (for NemoClaw sandbox)
- **Node.js 22+** and **npm 10+**
- **Ollama**: `brew install ollama` (or see [ollama.com](https://ollama.com))
- **Python 3.9+** (for channel resolution in scripts)

### 2. Install NemoClaw

```bash
curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash
```

### 3. Pull the model

```bash
ollama pull gemma4
```

### 4. Create the sandbox

```bash
NEMOCLAW_PROVIDER=ollama \
  NEMOCLAW_MODEL=gemma4 \
  nemoclaw onboard --non-interactive
```

Or run `nemoclaw onboard` for the interactive wizard.

### 5. Create a Slack app

1. Go to [api.slack.com/apps](https://api.slack.com/apps) → Create New App
2. Add bot scopes: `chat:write`, `channels:read`, `channels:history`
3. Install to your workspace
4. Copy the **Bot User OAuth Token** (`xoxb-...`)

### 6. Configure TRII

```bash
cp .env.example .env
# Edit .env with your Slack bot token

# Edit trii.conf — set TRII_HOME, MODEL_BACKEND, MODEL_NAME
# Edit channels.json — add your Slack channel IDs
```

### 7. Verify

```bash
# Test messaging
./post-message.sh general "TRII online"

# Test agent
./run-agent.sh "Say hello"

# Test full run
bash trii-run.sh
```

### 8. Schedule (optional)

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

### `post-message.sh`

Sends a message to the configured messaging backend. Supports:
- `slack` — Slack `chat.postMessage` API
- `stdout` — Print to terminal (for testing)

To add a new backend, add a case to the relevant adapter script.

## File Structure

```
TRII/
├── trii.conf              # All configuration
├── channels.json          # Channel map (name → ID)
├── run-agent.sh           # Model adapter
├── post-message.sh        # Messaging adapter
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
