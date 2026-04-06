# TRII Installation Guide

Step-by-step guide with known gotchas from real installs on Apple Silicon.

---

## Prerequisites

- **macOS with Apple Silicon** (M1/M2/M3/M4)
- **16GB RAM** recommended (8GB minimum)
- **Homebrew** installed
- **12GB+ free disk space** (sandbox image is ~2.5GB, Ollama models ~10GB)
- **Google Cloud project with billing enabled** (for Gemini API)

> **Tip:** `df -h /` on macOS with APFS lies about free space. Use `diskutil info / | grep "Container Free Space"` for the real number.

---

## 1. Install Colima (Docker runtime)

```bash
brew install colima docker
colima start --cpu 4 --memory 8
```

**Gotcha:** After a reboot, Colima doesn't auto-start. Run `colima start` before anything Docker-related.

---

## 2. Install NemoClaw

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

## 3. Create the NemoClaw sandbox with Gemini

You need a **Gemini API key from a billing-enabled GCP project**. Free-tier keys hit rate limits almost immediately with agent workloads.

1. Go to [aistudio.google.com/apikey](https://aistudio.google.com/apikey)
2. Click "Create API Key"
3. **Select your billing-enabled project** from the dropdown
4. Copy the key

Then create the sandbox:

```bash
GEMINI_API_KEY="your-billing-enabled-key" \
  NEMOCLAW_PROVIDER=gemini \
  NEMOCLAW_MODEL=gemini-2.5-flash \
  NEMOCLAW_NON_INTERACTIVE=1 \
  nemoclaw onboard --non-interactive --yes-i-accept-third-party-software
```

After onboard, increase the inference timeout (Gemini tool-calling can take time):

```bash
openshell inference update --timeout 180 --no-verify
```

**Gotcha (free tier key):** Free-tier Gemini API keys have very low RPM limits. OpenClaw retries on failure, which burns through the quota fast. You will see `API rate limit reached` errors constantly. **Always use a billing-enabled key.**

**Gotcha (API key type):** The `openshell provider` uses a field called `OPENAI_API_KEY` internally — this is just the generic name for the credential in the `openai`-compatible provider type. Your Gemini key goes here. No data goes to OpenAI.

**Gotcha (model config locked):** The sandbox's `openclaw.json` is baked in read-only at build time. To change the model or API type, you must destroy and rebuild the sandbox:

```bash
nemoclaw my-assistant destroy --yes
# Then re-run the onboard command above
```

---

## 4. Copy projects into the sandbox

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

**Gotcha:** `git clone` from GitHub requires credentials. For private repos, use tar-over-ssh to copy files in.

### Adding Google API access (for DSPI, Calendar, Gmail, NotebookLM)

The sandbox can access Google APIs — but the network policy must be configured correctly. Two critical details:

1. **Use `access: full`** (not `protocol: rest` with `tls: terminate`). The `access: full` mode creates a raw CONNECT tunnel that bypasses TLS termination. This is required because compiled binaries like `gws` (Rust) use their own TLS stack and reject the proxy's re-signed certificates.

2. **Use wildcard binary paths** (`/usr/bin/python3*` not `/usr/bin/python3`). The proxy resolves symlinks before checking — `/usr/bin/python3` is a symlink to `/usr/bin/python3.11`, and the exact path doesn't match without a wildcard.

**Gotcha:** Without the wildcard, `curl` works but Python gets 403 Forbidden from the proxy. The PyPI preset (which works for `pip install`) uses `/usr/bin/python3*` — follow that pattern.

Export and update the policy:

```bash
openshell policy get my-assistant --full | sed '1,/^---$/d' > /tmp/policy.yaml
```

Add this section under `network_policies:`:

```yaml
  google_apis:
    name: google_apis
    endpoints:
    - host: www.googleapis.com
      port: 443
      access: full
    - host: gmail.googleapis.com
      port: 443
      access: full
    - host: oauth2.googleapis.com
      port: 443
      access: full
    - host: accounts.google.com
      port: 443
      access: full
    - host: notebooklm.google.com
      port: 443
      access: full
    - host: us-central1-aiplatform.googleapis.com
      port: 443
      access: full
    - host: generativelanguage.googleapis.com
      port: 443
      access: full
    binaries:
    - path: /usr/bin/python3*
    - path: /usr/local/bin/python3*
    - path: /sandbox/.local/bin/python*
    - path: /sandbox/.local/bin/dspi
    - path: /sandbox/.local/bin/nb
    - path: /sandbox/.local/bin/email
    - path: /sandbox/.local/bin/gws
    - path: /usr/local/bin/node
    - path: /usr/local/bin/openclaw
    - path: /usr/bin/curl
```

For Playwright (needed by `nb` for NotebookLM), also add:

```yaml
  playwright_cdn:
    name: playwright_cdn
    endpoints:
    - host: cdn.playwright.dev
      port: 443
      access: full
    - host: playwright.download.prss.microsoft.com
      port: 443
      access: full
    binaries:
    - path: /usr/local/bin/node
    - path: /usr/bin/python3*
    - path: /usr/bin/curl
```

Apply:

```bash
openshell policy set my-assistant --policy /tmp/policy.yaml --wait
```

### Injecting credentials into the sandbox

Tools that need Google OAuth (DSPI, gws, nb) require credentials injected from the host:

```bash
# Refresh OAuth token and inject email-wizard config
python3 -c "
import json, urllib.request, time
path = '$HOME/.config/email-wizard/config.json'
c = json.load(open(path))
data = json.dumps({
    'client_id': c['oauth_client_id'],
    'client_secret': c.get('oauth_client_secret',''),
    'refresh_token': c['oauth_refresh_token'],
    'grant_type': 'refresh_token'
}).encode()
req = urllib.request.Request('https://oauth2.googleapis.com/token', data=data, headers={'Content-Type':'application/json'})
resp = json.loads(urllib.request.urlopen(req).read())
c['oauth_access_token'] = resp['access_token']
c['oauth_expires_at'] = time.time() + resp.get('expires_in', 3600)
json.dump(c, open(path, 'w'), indent=2)
print(json.dumps(c))
" | ssh -F /tmp/nc-ssh openshell-my-assistant \
  'mkdir -p /sandbox/.config/email-wizard && cat > /sandbox/.config/email-wizard/config.json && chmod 600 /sandbox/.config/email-wizard/config.json'

# Inject gws credentials
tar -C ~/.config -cf - gws | ssh -F /tmp/nc-ssh openshell-my-assistant \
  'mkdir -p /sandbox/.config && tar -C /sandbox/.config -xf -'

# Inject NotebookLM auth (for nb)
cat ~/.notebooklm/storage_state.json | ssh -F /tmp/nc-ssh openshell-my-assistant \
  'mkdir -p /sandbox/.notebooklm && cat > /sandbox/.notebooklm/storage_state.json && chmod 600 /sandbox/.notebooklm/storage_state.json'
```

**Gotcha:** OAuth tokens expire after ~1 hour. Re-inject before agent runs, or add a refresh step to `run-agent.sh`.

---

## 5. Configure Slack

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
# Edit .env: add both tokens (SLACK_BOT_TOKEN and SLACK_APP_TOKEN)

# Edit channels.json: set your channel ID
# Get channel ID: right-click channel in Slack → View channel details → scroll to bottom
```

### Test messaging

```bash
# Test one-way post to Slack
./post-message.sh general "TRII online"
```

---

## 6. Socket Mode listener setup

The listener bridges Slack into TRII's dispatch system. @mentions and DMs create dispatch JSON files, which the agent picks up and processes.

```bash
# Create virtual environment and install dependency
python3 -m venv .venv
.venv/bin/pip install websocket-client

# Test manually
.venv/bin/python3 slack-listener.py

# Install as persistent daemon (auto-restarts on crash)
cp com.trii.slack-listener.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.trii.slack-listener.plist
```

### How it works

1. User sends `@TRII_Bot do something` in Slack
2. Listener writes `dispatch/{timestamp}-slack.json`
3. Listener sends "Dispatched. Working on it." ack to Slack
4. Listener kicks `dispatch-watcher.sh`
5. Dispatch watcher runs `run-agent.sh` which:
   - Refreshes OAuth tokens (if needed for DSPI)
   - Injects DSPI dashboard data if task mentions calendar/meetings/inbox
   - SSHs into NemoClaw sandbox and runs the OpenClaw agent
6. Agent response is posted back to Slack

---

## 7. Schedule TRII cron (optional)

For autonomous scheduled runs (not just Slack-triggered):

```bash
# Edit plist with your actual path
sed -i '' "s|/CHANGE_ME/TRII|$(pwd)|g" com.trii.run.plist
cp com.trii.run.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.trii.run.plist
```

This runs `trii-run.sh` every hour, which rotates through projects in `RADAR.md`.

---

## 8. Verify everything works

```bash
# 1. Sandbox is running
nemoclaw my-assistant status

# 2. Agent responds (direct test)
openshell sandbox ssh-config my-assistant > /tmp/nc-ssh && chmod 600 /tmp/nc-ssh
ssh -T -F /tmp/nc-ssh openshell-my-assistant \
  'openclaw agent --agent main --local -m "say hello" --session-id verify-1 2>&1'

# 3. Slack messaging works
./post-message.sh general "TRII verification complete"

# 4. Slack listener is connected
.venv/bin/python3 slack-listener.py  # should print [ws] connected.

# 5. Full pipeline: @mention the bot in Slack and verify response comes back
```

---

## Post-reboot checklist

After a Mac restart, these services need to be running:

1. **Colima:** `colima start --cpu 4 --memory 8`
2. **Ollama** (if using local model): starts automatically via Homebrew
3. **Slack listener:** starts automatically if launchd plist is loaded, otherwise: `.venv/bin/python3 slack-listener.py`

The NemoClaw sandbox persists across Colima restarts. Verify with `nemoclaw my-assistant status`.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `unable to find user sandbox` | Stale GHCR base image | Rebuild locally: `cd ~/.nemoclaw/source && docker build -f Dockerfile.base -t ghcr.io/nvidia/nemoclaw/sandbox-base:latest .` |
| `python3: Exec format error` | Base image has corrupted binaries | Same fix — rebuild locally |
| `setsid: command not found` | macOS doesn't have setsid | Included shim at `bin/setsid` — ensure `PATH` includes it |
| `LLM request timed out` | Inference timeout too low | `openshell inference update --timeout 180 --no-verify` |
| `API rate limit reached` | Free-tier Gemini API key | Use a key from a billing-enabled GCP project |
| `400 status code (no body)` | Model config mismatch in sandbox | Rebuild sandbox: `nemoclaw my-assistant destroy --yes` then re-onboard |
| `401 status code` | Expired or invalid API key | Update provider: `openshell provider update gemini-api --credential "OPENAI_API_KEY=new-key"` |
| `session file locked` | Stale lock from crashed agent | `ssh ... 'rm -f /sandbox/.openclaw-data/agents/main/sessions/*.lock'` |
| `channel_not_found` | Bot not invited to channel | `/invite @BotName` in Slack channel |
| Docker/colima hangs | VM ran out of resources | `colima stop -f && colima start --cpu 4 --memory 8` |
| `df` shows 0 free space | APFS purgeable space not counted | Use `diskutil info / \| grep "Container Free Space"` |
| Python gets `403 Forbidden` but curl works | Binary path mismatch in network policy | Use wildcard paths: `/usr/bin/python3*` not `/usr/bin/python3` (proxy resolves symlinks) |
| `gws` gets "Failed to send token refresh request" | TLS termination breaks compiled binaries | Use `access: full` (not `protocol: rest` with `tls: terminate`) for the endpoint |
| DSPI shows no calendar/inbox data | Missing network policy or credentials | Add `google_apis` policy with `access: full` + wildcard binaries, then inject fresh OAuth config |
| `could not read Username for GitHub` | No GitHub auth in sandbox | Use tar-over-ssh to copy files instead of git clone |
