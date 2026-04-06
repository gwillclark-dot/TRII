#!/bin/bash
# dispatch-watcher.sh — Process dispatch requests from dispatch/ directory
#
# Dispatch JSON schema (model-agnostic, messenger-agnostic):
# {
#   "project": "project-name",
#   "task": "what to do",
#   "channel": "general"        // logical channel name or raw ID
# }

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$SCRIPT_DIR/bin:$PATH"
source "$SCRIPT_DIR/trii.conf"
source "$SCRIPT_DIR/resolve-project.sh"

# Load .env for tokens
if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a
  source "$SCRIPT_DIR/.env"
  set +a
fi

export HOME="${HOME:-$(eval echo ~)}"
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

DISPATCH_DIR="$SCRIPT_DIR/dispatch"
DONE_DIR="$SCRIPT_DIR/dispatch/done"
LOG_DIR="$SCRIPT_DIR/session-log"

mkdir -p "$DONE_DIR" "$LOG_DIR"

for f in "$DISPATCH_DIR"/*.json; do
  [ -f "$f" ] || continue

  TIMESTAMP=$(date +%Y-%m-%d-%H%M)
  LOGFILE="${LOG_DIR}/dispatch-${TIMESTAMP}.log"

  # Parse dispatch request
  PROJECT=$(python3 -c "import json; print(json.load(open('$f')).get('project','trii'))")
  TASK=$(python3 -c "import json; print(json.load(open('$f')).get('task','No task specified'))")
  CHANNEL=$(python3 -c "import json; print(json.load(open('$f')).get('channel','general'))")

  # Resolve project directory via shared helper
  WORK_DIR=$(resolve_project_dir "$PROJECT")

  echo "=== Dispatch run starting at $(date) ===" > "$LOGFILE"
  echo "Project: $PROJECT ($WORK_DIR)" >> "$LOGFILE"
  echo "Task: $TASK" >> "$LOGFILE"
  echo "" >> "$LOGFILE"

  # Map project to sandbox path (agent runs inside NemoClaw sandbox)
  SANDBOX_WORK_DIR="/sandbox/${PROJECT}"

  PROMPT="You are TRII, an autonomous coding agent.

CRITICAL: Your project files are at /sandbox/${PROJECT}/ (NOT in your default workspace directory).
Run: ls /sandbox/${PROJECT}/ to see the actual project files before doing anything else.

Available projects under /sandbox/: GWS_CLI, KNOWLEDGE_CLI, Conductor_CLI

Your task: ${TASK}

Rules:
- Always use absolute paths starting with /sandbox/${PROJECT}/
- Use tools to read files and run commands. Do not describe what you would do — do it.
- Output only the final result. No plans, no step narration.
- Keep response under 500 words.

## Host Actions
You can request host-side operations by outputting this directive on its own line:
%%%HOST_ACTION:action-name%%%

Available actions:
- restart-gateway — restart the sandbox OpenClaw gateway
- reload-listener — restart the Slack listener
- refresh-tokens — refresh Google OAuth tokens
- sync-project-gws — re-sync GWS_CLI from host to sandbox
- sync-project-knowledge — re-sync KNOWLEDGE_CLI from host to sandbox

Actions execute AFTER your session ends. You will not see the result.
Only request an action when the current task requires it."

  # Clear previous session state so each dispatch starts fresh
  CONF_TMP=$(mktemp -d)
  if openshell sandbox ssh-config my-assistant > "$CONF_TMP/config" 2>/dev/null; then
    chmod 600 "$CONF_TMP/config"
    ssh -T -F "$CONF_TMP/config" openshell-my-assistant \
      'rm -f /sandbox/.openclaw-data/agents/main/sessions/*.jsonl /sandbox/.openclaw-data/agents/main/sessions/*.lock /sandbox/.openclaw-data/agents/main/sessions/sessions.json' 2>/dev/null || true
  fi
  rm -rf "$CONF_TMP"

  # Execute via adapter (in project directory, own process group)
  cd "$WORK_DIR"

  STDOUT_FILE="$SCRIPT_DIR/session-log/.dispatch-stdout-${TIMESTAMP}"
  setsid "$SCRIPT_DIR/run-agent.sh" "$PROMPT" "dispatch-${TIMESTAMP}" > "$STDOUT_FILE" 2>> "$LOGFILE" &
  AGENT_PID=$!
  AGENT_PGID=$(ps -o pgid= -p "$AGENT_PID" 2>/dev/null | tr -d ' ')

  # Watchdog — kills entire process group (ssh, ollama, openclaw children)
  (
    sleep "$TIMEOUT"
    if kill -0 "$AGENT_PID" 2>/dev/null; then
      kill -- -"$AGENT_PGID" 2>/dev/null
      echo "=== TIMEOUT: Dispatch killed after ${TIMEOUT}s at $(date) ===" >> "$LOGFILE"
    fi
  ) &
  WATCHDOG_PID=$!

  wait "$AGENT_PID"
  EXIT_CODE=$?

  kill "$WATCHDOG_PID" 2>/dev/null
  wait "$WATCHDOG_PID" 2>/dev/null

  cd "$SCRIPT_DIR"

  # Handle result — clear success vs failure
  if [ $EXIT_CODE -ne 0 ]; then
    echo "=== Dispatch FAILED (exit $EXIT_CODE) at $(date) ===" >> "$LOGFILE"
    "$SCRIPT_DIR/post-message.sh" "$CHANNEL" \
      "❌ Dispatch failed for ${PROJECT} (exit $EXIT_CODE). Check session-log/dispatch-${TIMESTAMP}.log" \
      2>/dev/null || true
  else
    echo "=== Dispatch completed at $(date) ===" >> "$LOGFILE"
    # Post agent response to Slack (strip host action directives)
    if [ -s "$STDOUT_FILE" ]; then
      RESPONSE=$(grep -v '%%%HOST_ACTION:' "$STDOUT_FILE" | tail -10 | head -c 3000)
      if [ -n "$(echo "$RESPONSE" | tr -d '[:space:]')" ]; then
        "$SCRIPT_DIR/post-message.sh" "$CHANNEL" "$RESPONSE" 2>/dev/null || true
      fi
    else
      "$SCRIPT_DIR/post-message.sh" "$CHANNEL" "✅ Dispatch for ${PROJECT} completed (no output)." 2>/dev/null || true
    fi
  fi

  # Extract and execute host-side actions from agent output
  if [ -s "$STDOUT_FILE" ]; then
    grep -oE '%%%HOST_ACTION:[a-z0-9][-a-z0-9]*%%%' "$STDOUT_FILE" \
      | sed 's/%%%HOST_ACTION://;s/%%%//' \
      | head -3 \
      | while read -r HA; do
          echo "Host action requested: $HA" >> "$LOGFILE"
          "$SCRIPT_DIR/exec-host-action.sh" "$HA" "$CHANNEL" >> "$LOGFILE" 2>&1 || true
        done
  fi

  # Push changes
  for REPO_DIR in "$SCRIPT_DIR" "$WORK_DIR"; do
    if [ -d "$REPO_DIR/.git" ]; then
      cd "$REPO_DIR"
      git push origin main >> "$LOGFILE" 2>&1 || true
    fi
  done
  cd "$SCRIPT_DIR"

  # Move to done
  mv "$f" "$DONE_DIR/$(basename "$f" .json)-${TIMESTAMP}.json"
done
