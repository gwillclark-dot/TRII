#!/bin/bash
# trii-run.sh — Main orchestrator for TRII
#
# Runs on a schedule via launchd. Each invocation:
# 1. Checks for pending dispatches (priority)
# 2. Picks next project from rotation
# 3. Executes via run-agent.sh
# 4. Posts results via post-message.sh
# 5. Logs to session-log/

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/trii.conf"

# Load .env for tokens
if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a
  source "$SCRIPT_DIR/.env"
  set +a
fi

export HOME="${HOME:-$(eval echo ~)}"
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# Create session-log directory if needed
mkdir -p "$SCRIPT_DIR/session-log"

# Timestamped log file
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
# Format: ("project1" "project2" "debug")
PROJECTS=()

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

# --- Read channel for this project ---
PROJECT_CHANNEL=$(python3 -c "
import json
with open('$SCRIPT_DIR/channels.json') as f:
    channels = json.load(f)
ch = channels.get('$RUN_TARGET', channels.get('general', {}))
print(ch.get('id', ''))
" 2>/dev/null)

# --- Build prompt ---
# Identity header — sent with every run
IDENTITY="You are TRII — an autonomous technical operator. Ship code, surface signal, stay out of the way.

## Voice Rules
- Brevity is respect. Lead with outcome, not process.
- Messages: max 2-3 lines. Status emoji up front. No greetings, no sign-offs, no filler.
- If something is complex, explain the why in one line.
- When escalating: state the decision, the options, your recommendation.

## Messaging
To post status updates, write your message to stdout. The orchestrator will route it.

## This run: $RUN_TARGET
Read the project's NEXT_STEPS.md and PROJECT_STATUS.md, pick the highest-priority task, execute it.

Steps:
1. Read project state files
2. Pick task, implement it
3. Run tests/validation if applicable
4. Commit changes
5. Write a 1-2 line summary of what you did

Rules:
- Autonomous. Read code, don't ask for context you can find.
- INBOX.md only for decisions requiring a human.
- Target 5 minutes."

# --- Background watchdog ---
(
  sleep "$TIMEOUT"
  pkill -f "run-agent.sh.*trii-${TIMESTAMP}" 2>/dev/null && \
    echo "=== TIMEOUT: Run killed after ${TIMEOUT}s at $(date) ===" >> "$LOGFILE" && \
    "$SCRIPT_DIR/post-message.sh" "${PROJECT_CHANNEL:-general}" \
      "⚠️ TRII run timed out after ${TIMEOUT}s. Check session-log/${TIMESTAMP}.log" \
      2>/dev/null
) &
WATCHDOG_PID=$!

# --- Execute ---
echo "=== Agent execution starting at $(date) ===" >> "$LOGFILE"

AGENT_OUTPUT=$("$SCRIPT_DIR/run-agent.sh" "$IDENTITY" "trii-${TIMESTAMP}" 2>> "$LOGFILE") || true
echo "$AGENT_OUTPUT" >> "$LOGFILE"

# Kill watchdog
kill $WATCHDOG_PID 2>/dev/null
wait $WATCHDOG_PID 2>/dev/null

# --- Post result ---
if [ -n "$AGENT_OUTPUT" ] && [ -n "$PROJECT_CHANNEL" ]; then
  # Extract last meaningful line as summary
  SUMMARY=$(echo "$AGENT_OUTPUT" | grep -v '^\s*$' | tail -3)
  "$SCRIPT_DIR/post-message.sh" "${PROJECT_CHANNEL}" "$SUMMARY" 2>> "$LOGFILE" || true
fi

echo "=== TRII run completed at $(date) ===" >> "$LOGFILE"

# --- Auto-push repos ---
echo "=== Pushing to GitHub ===" >> "$LOGFILE"
for REPO_DIR in "$SCRIPT_DIR" "$SCRIPT_DIR"/*/; do
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
