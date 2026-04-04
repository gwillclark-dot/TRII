# TRII Installation Guide

Step-by-step guide with known gotchas from real installs on Apple Silicon.

---

## Prerequisites

- **macOS with Apple Silicon** (M1/M2/M3/M4)
- **16GB RAM** recommended (8GB minimum)
- **Homebrew** installed
- **12GB+ free disk space** (sandbox image is ~2.5GB, Ollama models ~10GB)

> **Tip:** `df -h /` on macOS with APFS lies about free space. Use `diskutil info / | grep "Container Free Space"` for the real number.

---

## 1. Install Colima (Docker runtime)

```bash
brew install colima docker
colima start --cpu 4 --memory 8
```

**Gotcha:** After a reboot, Colima doesn't auto-start. Run `colima start` before anything Docker-related.

---

## 2. Install Ollama

```bash
brew install ollama
ollama pull gemma4  # ~10GB, takes a while
```

Ollama auto-starts as a background service via Homebrew.

**Gotcha:** Ollama defaults to listening on `127.0.0.1` only. For NemoClaw (which runs in a Colima VM), Ollama must be reachable from inside the VM. If using the `ollama` backend with NemoClaw:

```bash
launchctl setenv OLLAMA_HOST "0.0.0.0:11434"
brew services restart ollama
```

Then update the OpenShell provider to use the Colima host IP (not `localhost`):

```bash
# Find the host IP from Colima's perspective:
colima ssh -- ip route show default  # look for "via X.X.X.X"
openshell provider update ollama-local --config "OPENAI_BASE_URL=http://X.X.X.X:11434/v1"
```

---

## 3. Install NemoClaw

```bash
curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash
source ~/.zshrc
```

### Known issue: sandbox-base image missing `sandbox` user

The published `ghcr.io/nvidia/nemoclaw/sandbox-base:latest` image may be missing the `sandbox` user, causing the build to fail at `USER sandbox` with:

```
Docker stream error: unable to find user sandbox: no matching entries in passwd file
```

**Fix:** Rebuild the base image locally from NemoClaw's source:

```bash
cd ~/.nemoclaw/source
docker build -f Dockerfile.base -t ghcr.io/nvidia/nemoclaw/sandbox-base:latest .
```

This takes 3-5 minutes and ensures the `sandbox` user exists.

### Known issue: `setsid` not found on macOS

TRII's scripts use `setsid` (Linux command) for process group isolation. macOS doesn't have it.

**Fix:** TRII includes a shim at `bin/setsid` that uses Perl's POSIX module. The scripts automatically add `bin/` to PATH.

---

## 4. Create the NemoClaw sandbox

### Option A: With Gemini (recommended)

```bash
GEMINI_API_KEY="your-key-here" \
  NEMOCLAW_PROVIDER=gemini \
  NEMOCLAW_MODEL=gemini-2.5-flash \
  NEMOCLAW_NON_INTERACTIVE=1 \
  nemoclaw onboard --non-interactive --yes-i-accept-third-party-software
```

### Option B: With local Ollama

```bash
NEMOCLAW_PROVIDER=ollama \
  NEMOCLAW_MODEL=gemma4 \
  NEMOCLAW_NON_INTERACTIVE=1 \
  nemoclaw onboard --non-interactive --yes-i-accept-third-party-software
```

**Gotcha (Ollama):** After onboard, the inference provider may point at `localhost:11434` which is unreachable from inside the Colima VM. Update the provider to use the host IP (see step 2).

**Gotcha (Ollama):** The default inference timeout is 60s. Gemma4 on M1 needs ~50s for cold start. Increase it:

```bash
openshell inference update --timeout 180 --no-verify
```

---

## 5. Copy projects into the sandbox

The sandbox has an isolated filesystem at `/sandbox/`. Projects must be copied in:

```bash
# Get SSH config
openshell sandbox ssh-config my-assistant > /tmp/nc-ssh
chmod 600 /tmp/nc-ssh

# Copy a project (excluding heavy dirs)
tar -C ~/path/to/projects -cf - \
  --exclude='node_modules' --exclude='.venv' --exclude='__pycache__' --exclude='.git' \
  PROJECT_NAME | ssh -F /tmp/nc-ssh openshell-my-assistant 'tar -C /sandbox -xf -'

# Init git inside sandbox
ssh -T -F /tmp/nc-ssh openshell-my-assistant '
  git config --global user.email "trii@sandbox.local"
  git config --global user.name "TRII Agent"
  git config --global init.defaultBranch main
  cd /sandbox/PROJECT_NAME && git init -q && git add -A && git commit -m "initial import" -q
'
```

**Gotcha:** `scp` doesn't work (no sftp-server in sandbox). Use tar-over-ssh instead.

**Gotcha:** `git clone` from GitHub requires credentials. For private repos, either SCP files in or set up a GitHub PAT inside the sandbox.

---

## 6. Configure Slack

### Create the Slack app

1. Go to [api.slack.com/apps](https://api.slack.com/apps) → Create New App → From Scratch
2. **App Home** → toggle on Messages Tab (this creates the bot user)
3. **OAuth & Permissions** → add Bot Token Scopes:
   - `chat:write`
   - `channels:read`
   - `channels:history`
   - `app_mentions:read`
   - `im:read`
   - `im:history`
4. **Install to Workspace** → authorize → copy **Bot User OAuth Token** (`xoxb-...`)
5. **Socket Mode** → toggle ON → generate **App-Level Token** with `connections:write` scope → copy token (`xapp-...`)
6. **Event Subscriptions** → toggle ON → Subscribe to bot events:
   - `app_mention`
   - `message.im`
7. **Reinstall app** to workspace after adding scopes
8. **Invite the bot** to your channel: `/invite @YourBotName`

**Gotcha:** You must create the bot user (step 2) BEFORE installing to workspace. Otherwise you get "doesn't have a bot user to install."

**Gotcha:** The `xapp-` token is NOT the bot token. You need BOTH:
- `xoxb-...` (Bot User OAuth Token) — for posting messages
- `xapp-...` (App-Level Token) — for Socket Mode listener

### Configure TRII

```bash
cp .env.example .env
# Edit .env: add both tokens

# Edit channels.json: set your channel ID
# Get channel ID: right-click channel in Slack → View channel details → scroll to bottom
```

### Test

```bash
# Test messaging (one-way post)
./post-message.sh general "TRII online"

# Start the Socket Mode listener
.venv/bin/python3 slack-listener.py
```

---

## 7. Socket Mode listener setup

```bash
# Create virtual environment and install dependency
python3 -m venv .venv
.venv/bin/pip install websocket-client

# Test manually
.venv/bin/python3 slack-listener.py

# Install as persistent daemon
cp com.trii.slack-listener.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.trii.slack-listener.plist
```

---

## 8. Schedule TRII (optional)

Edit `com.trii.run.plist` — replace `/CHANGE_ME/TRII` with your actual path:

```bash
sed -i '' "s|/CHANGE_ME/TRII|$(pwd)|g" com.trii.run.plist
cp com.trii.run.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.trii.run.plist
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `unable to find user sandbox` | Stale GHCR base image | Rebuild locally: `cd ~/.nemoclaw/source && docker build -f Dockerfile.base -t ghcr.io/nvidia/nemoclaw/sandbox-base:latest .` |
| `python3: Exec format error` | Base image has corrupted binaries | Same fix — rebuild locally |
| `setsid: command not found` | macOS doesn't have setsid | Included shim at `bin/setsid` — ensure `PATH` includes it |
| `LLM request timed out` | Inference timeout too low for model | `openshell inference update --timeout 180 --no-verify` |
| `400 status code (no body)` | Model config mismatch in sandbox | Rebuild sandbox with correct provider/model |
| `session file locked` | Stale lock from crashed agent | `ssh ... 'rm -f /sandbox/.openclaw-data/agents/main/sessions/*.lock'` |
| `channel_not_found` | Bot not invited to channel | `/invite @BotName` in Slack channel |
| Docker/colima hangs | VM ran out of resources during build | `colima stop -f && colima start --cpu 4 --memory 8` |
| `df` shows 0 free space | APFS purgeable space not counted | Use `diskutil info / \| grep "Container Free Space"` |
