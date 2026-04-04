#!/bin/bash
# run-agent.sh — Execute a prompt with the configured local model
# Usage: run-agent.sh <prompt> [session-id]
#
# Reads MODEL_BACKEND, MODEL_NAME, SANDBOX_NAME from trii.conf.
# Agent response goes to stdout. Logs/errors go to stderr.
# Exits non-zero on any backend failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/trii.conf"

PROMPT="${1:?Usage: run-agent.sh <prompt> [session-id]}"
SESSION_ID="${2:-trii-$$}"

# Fail-fast dependency checks per backend
check_command() {
  if ! command -v "$1" &>/dev/null; then
    echo "ERROR: '$1' not found. Install it before using MODEL_BACKEND=$MODEL_BACKEND." >&2
    echo "Run 'bash setup.sh' for guided installation." >&2
    exit 127
  fi
}

case "$MODEL_BACKEND" in
  nemoclaw)
    check_command openshell
    check_command ssh

    CONF_DIR=$(mktemp -d)
    CONF_FILE="$CONF_DIR/config"
    trap 'rm -f "$CONF_FILE"; rmdir "$CONF_DIR" 2>/dev/null' EXIT

    if ! openshell sandbox ssh-config "$SANDBOX_NAME" > "$CONF_FILE" 2>/dev/null; then
      echo "ERROR: Failed to get SSH config for sandbox '$SANDBOX_NAME'." >&2
      echo "Is the sandbox running? Check with: nemoclaw $SANDBOX_NAME status" >&2
      exit 1
    fi
    chmod 600 "$CONF_FILE"

    # Refresh Vertex AI OAuth token and update gateway provider
    FRESH_TOKEN=$("$SCRIPT_DIR/refresh-vertex-token.sh" 2>/dev/null)
    if [ -n "$FRESH_TOKEN" ]; then
      openshell provider update gemini-api \
        --credential "GEMINI_API_KEY=$FRESH_TOKEN" >/dev/null 2>&1 || true
    fi

    # Inject host-side data when keywords match (Google OAuth tools can't run in sandbox)
    HOST_CONTEXT=""

    # "calendar" triggers 14-day calendar injection
    if echo "$PROMPT" | grep -qiE 'calendar|meeting|schedule|monday|tuesday|wednesday|thursday|friday|next week|this week'; then
      CALENDAR_OUTPUT=$(python3 -c "
import sys
sys.path.insert(0, '$HOME/Desktop/Projects.nosync/GWS_CLI')
from dspi.calendar_ctx import get_upcoming_events, build_calendar_context_string
events = get_upcoming_events(days=14)
print(build_calendar_context_string(events))
" 2>/dev/null)
      if [ -n "$CALENDAR_OUTPUT" ]; then
        HOST_CONTEXT="14-day calendar (live):
${CALENDAR_OUTPUT}"
      fi
    fi

    # "dspi/inbox/contracts" triggers dashboard injection
    if echo "$PROMPT" | grep -qiE 'dspi|inbox|email|contract|alert|status'; then
      DSPI_OUTPUT=$(dspi status 2>/dev/null | head -60)
      if [ -n "$DSPI_OUTPUT" ]; then
        HOST_CONTEXT="${HOST_CONTEXT}${HOST_CONTEXT:+

}DSPI Dashboard (live):
${DSPI_OUTPUT}"
      fi
    fi

    if [ -n "$HOST_CONTEXT" ]; then
      PROMPT="## Live Context (from host)

${HOST_CONTEXT}

---

${PROMPT}"
    fi

    ssh -T -F "$CONF_FILE" "openshell-${SANDBOX_NAME}" \
      "openclaw agent --agent main --local -m $(printf '%q' "$PROMPT") --session-id $(printf '%q' "$SESSION_ID")"
    ;;

  ollama)
    check_command ollama

    # Verify model is available
    if ! ollama list 2>/dev/null | grep -q "$MODEL_NAME"; then
      echo "ERROR: Model '$MODEL_NAME' not found in Ollama. Pull it with: ollama pull $MODEL_NAME" >&2
      exit 1
    fi

    ollama run "$MODEL_NAME" "$PROMPT"
    ;;

  llamacpp)
    check_command curl
    LLAMACPP_URL="${LLAMACPP_SERVER:-http://localhost:8080}"

    # Verify server is reachable
    if ! curl -sf "$LLAMACPP_URL/health" &>/dev/null; then
      echo "ERROR: llama.cpp server not reachable at $LLAMACPP_URL" >&2
      exit 1
    fi

    curl -s "$LLAMACPP_URL/completion" \
      -H "Content-Type: application/json" \
      -d "{\"prompt\": $(printf '%s' "$PROMPT" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'), \"n_predict\": 2048}" \
      | python3 -c "import json,sys; print(json.load(sys.stdin).get('content',''))"
    ;;

  *)
    echo "ERROR: Unknown MODEL_BACKEND '$MODEL_BACKEND'. Supported: nemoclaw, ollama, llamacpp" >&2
    exit 1
    ;;
esac
