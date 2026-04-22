#!/bin/bash
# trii-run.sh — Main orchestrator for TRII
#
# Runs on a schedule via launchd. Each invocation:
# 1. Checks for pending dispatches (priority)
# 2. Picks next project from rotation
# 3. cd's to project directory
# 4. Executes via run-agent.sh
# 5. Posts results via post-message.sh (only on success)
# 6. Logs to session-log/ with clear success/failure status

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

mkdir -p "$SCRIPT_DIR/session-log"

TIMESTAMP=$(date +%Y-%m-%d-%H%M)
LOGFILE="$SCRIPT_DIR/session-log/${TIMESTAMP}.log"

echo "=== TRII run starting at $(date) ===" > "$LOGFILE"

# --- Check for pending dispatch requests (priority) ---
DISPATCH_DIR="$SCRIPT_DIR/dispatch"
PENDING=$(ls "$DISPATCH_DIR"/*.json 2>/dev/null | head -1)
if [ -n "$PENDING" ]; then
  echo "Dispatch queue has pending requests — running dispatch-watcher first" >> "$LOGFILE"
  /bin/bash "$SCRIPT_DIR/dispatch-watcher.sh" >> "$LOGFILE" 2>&1
fi

# --- Project rotation ---
# Add projects to this array as you assign them.
# Each name must match a subdirectory under TRII_HOME (or examples/).
# Default ships with the hello-world smoke test — replace with your projects.
PROJECTS=("hello-world")

if [ ${#PROJECTS[@]} -eq 0 ]; then
  echo "No projects in rotation. Add projects to PROJECTS array in trii-run.sh." >> "$LOGFILE"
  echo "=== TRII run completed (no-op) at $(date) ===" >> "$LOGFILE"
  exit 0
fi

ROTATION_FILE="$SCRIPT_DIR/.run_rotation"
ROTATION=$(cat "$ROTATION_FILE" 2>/dev/null || echo "0")
RUN_TARGET="${PROJECTS[$ROTATION]}"
NEXT_ROTATION=$(( (ROTATION + 1) % ${#PROJECTS[@]} ))
echo "$NEXT_ROTATION" > "$ROTATION_FILE"
echo "Run rotation: slot $ROTATION/${#PROJECTS[@]} → target: $RUN_TARGET" >> "$LOGFILE"

# --- Resolve project directory ---
WORK_DIR=$(resolve_project_dir "$RUN_TARGET")
echo "Working directory: $WORK_DIR" >> "$LOGFILE"

# --- Read channel for this project ---
PROJECT_CHANNEL=$(python3 -c "
import json
with open('$SCRIPT_DIR/channels.json') as f:
    channels = json.load(f)
ch = channels.get('$RUN_TARGET', channels.get('general', {}))
print(ch.get('id', ''))
" 2>/dev/null || echo "")

# --- Build prompt ---
IDENTITY="You are TRII — an autonomous technical operator. Ship code, surface signal, stay out of the way.

## Voice Rules
- Brevity is respect. Lead with outcome, not process.
- Messages: max 2-3 lines. Status emoji up front. No greetings, no sign-offs, no filler.
- If something is complex, explain the why in one line.
- When escalating: state the decision, the options, your recommendation.

## Messaging
To post status updates, write your message to stdout. The orchestrator will route it.

## This run: $RUN_TARGET
Working directory: $WORK_DIR

Steps:
1. Read project state files (NEXT_STEPS.md, PROJECT_STATUS.md)
2. Pick the highest-priority task, implement it
3. Run tests/validation if applicable
4. Commit changes
5. Write a 1-2 line summary of what you did

Rules:
- Autonomous. Read code, don't ask for context you can find.
- INBOX.md only for decisions requiring a human.
- Target 5 minutes."

# --- Execute (cd to project directory, in own process group) ---
echo "=== Agent execution starting at $(date) ===" >> "$LOGFILE"

cd "$WORK_DIR"

# Run agent in a new process group (setsid) so watchdog can kill the
# entire tree — ssh, ollama, openclaw, and all children — not just the
# wrapper script.
setsid "$SCRIPT_DIR/run-agent.sh" "$IDENTITY" "trii-${TIMESTAMP}" \
  > "$SCRIPT_DIR/session-log/.agent-stdout-${TIMESTAMP}" \
  2>> "$LOGFILE" &
AGENT_PID=$!
AGENT_PGID=$(ps -o pgid= -p "$AGENT_PID" 2>/dev/null | tr -d ' ')

# --- Background watchdog (kills entire process group) ---
(
  sleep "$TIMEOUT"
  if kill -0 "$AGENT_PID" 2>/dev/null; then
    kill -- -"$AGENT_PGID" 2>/dev/null
    echo "=== TIMEOUT: Run killed after ${TIMEOUT}s at $(date) ===" >> "$LOGFILE"
    "$SCRIPT_DIR/post-message.sh" "${PROJECT_CHANNEL:-general}" \
      "⚠️ TRII run timed out after ${TIMEOUT}s ($RUN_TARGET). Check session-log/${TIMESTAMP}.log" \
      2>/dev/null || true
  fi
) &
WATCHDOG_PID=$!

wait "$AGENT_PID"
AGENT_EXIT=$?
AGENT_OUTPUT=$(cat "$SCRIPT_DIR/session-log/.agent-stdout-${TIMESTAMP}" 2>/dev/null)
rm -f "$SCRIPT_DIR/session-log/.agent-stdout-${TIMESTAMP}"
cd "$SCRIPT_DIR"

echo "$AGENT_OUTPUT" >> "$LOGFILE"

# Kill watchdog
kill $WATCHDOG_PID 2>/dev/null
wait $WATCHDOG_PID 2>/dev/null

# --- Handle result (never false-positive success) ---
if [ $AGENT_EXIT -ne 0 ]; then
  echo "=== TRII run FAILED (exit $AGENT_EXIT) at $(date) ===" >> "$LOGFILE"
  "$SCRIPT_DIR/post-message.sh" "${PROJECT_CHANNEL:-general}" \
    "❌ TRII run failed for $RUN_TARGET (exit $AGENT_EXIT). Check session-log/${TIMESTAMP}.log" \
    2>> "$LOGFILE" || true
  exit $AGENT_EXIT
fi

# --- Post result (success only) ---
if [ -n "$AGENT_OUTPUT" ] && [ -n "$PROJECT_CHANNEL" ]; then
  SUMMARY=$(echo "$AGENT_OUTPUT" | grep -v '^\s*$' | tail -3)
  "$SCRIPT_DIR/post-message.sh" "$PROJECT_CHANNEL" "$SUMMARY" 2>> "$LOGFILE" || true
fi

echo "=== TRII run completed at $(date) ===" >> "$LOGFILE"

# --- Auto-push repos ---
echo "=== Pushing to GitHub ===" >> "$LOGFILE"
for REPO_DIR in "$SCRIPT_DIR" "$WORK_DIR"; do
  if [ -d "$REPO_DIR/.git" ]; then
    REPO_NAME=$(basename "$REPO_DIR")
    cd "$REPO_DIR"
    if ! git diff --quiet HEAD @{u} 2>/dev/null; then
      git push origin main >> "$LOGFILE" 2>&1 && \
        echo "  $REPO_NAME: pushed" >> "$LOGFILE" || \
        echo "  $REPO_NAME: push failed" >> "$LOGFILE"
    else
      echo "  $REPO_NAME: up to date" >> "$LOGFILE"
    fi
  fi
done
cd "$SCRIPT_DIR"
