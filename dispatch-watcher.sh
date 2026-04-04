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
source "$SCRIPT_DIR/trii.conf"

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

  # Map project name to directory (add mappings as projects are assigned)
  case "$PROJECT" in
    trii|orchestrator) WORK_DIR="$SCRIPT_DIR" ;;
    *)                 WORK_DIR="$SCRIPT_DIR/$PROJECT" ;;
  esac

  # Fall back to TRII root if project dir doesn't exist
  [ -d "$WORK_DIR" ] || WORK_DIR="$SCRIPT_DIR"

  echo "=== Dispatch run starting at $(date) ===" > "$LOGFILE"
  echo "Project: $PROJECT ($WORK_DIR)" >> "$LOGFILE"
  echo "Task: $TASK" >> "$LOGFILE"
  echo "" >> "$LOGFILE"

  PROMPT="You are TRII — an autonomous technical operator. Ship code, surface signal, stay out of the way.

## Voice Rules
- Brevity is respect. Lead with outcome, not process.
- Messages: max 2-3 lines. Status emoji up front. No greetings, no sign-offs.

## DISPATCHED TASK
Project: ${PROJECT}
Working directory: ${WORK_DIR}

Task: ${TASK}

## Rules
- Ship it. Read code, make changes, commit, write result summary.
- Autonomous — all code is on disk. Never ask for context you can read.
- Work in ${WORK_DIR}. TRII-level changes → ${SCRIPT_DIR}.
- Needs human (keys, money, architecture) → INBOX.md.
- Target 5 minutes."

  # Execute via adapter
  cd "$WORK_DIR"

  "$SCRIPT_DIR/run-agent.sh" "$PROMPT" "dispatch-${TIMESTAMP}" >> "$LOGFILE" 2>&1 &
  AGENT_PID=$!

  # Watchdog
  ( sleep "$TIMEOUT" && kill "$AGENT_PID" 2>/dev/null && \
    echo "=== TIMEOUT: Dispatch killed after ${TIMEOUT}s at $(date) ===" >> "$LOGFILE" ) &
  WATCHDOG_PID=$!

  wait "$AGENT_PID"
  EXIT_CODE=$?

  kill "$WATCHDOG_PID" 2>/dev/null
  wait "$WATCHDOG_PID" 2>/dev/null

  cd "$SCRIPT_DIR"

  if [ $EXIT_CODE -ne 0 ]; then
    echo "=== Dispatch FAILED: Exit code $EXIT_CODE at $(date) ===" >> "$LOGFILE"
    "$SCRIPT_DIR/post-message.sh" "$CHANNEL" \
      "❌ Dispatch failed for ${PROJECT}: exit $EXIT_CODE. Check session-log/dispatch-${TIMESTAMP}.log" \
      2>/dev/null || true
  else
    echo "=== Dispatch completed at $(date) ===" >> "$LOGFILE"
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
