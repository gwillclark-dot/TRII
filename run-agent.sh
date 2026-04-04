#!/bin/bash
# run-agent.sh — Execute a prompt with the configured local model
# Usage: run-agent.sh <prompt> [session-id]
#
# Reads MODEL_BACKEND, MODEL_NAME, SANDBOX_NAME from trii.conf.
# Agent response goes to stdout. Logs/errors go to stderr.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/trii.conf"

PROMPT="${1:?Usage: run-agent.sh <prompt> [session-id]}"
SESSION_ID="${2:-trii-$$}"

case "$MODEL_BACKEND" in
  nemoclaw)
    CONF_DIR=$(mktemp -d)
    CONF_FILE="$CONF_DIR/config"
    trap 'rm -f "$CONF_FILE"; rmdir "$CONF_DIR" 2>/dev/null' EXIT

    openshell sandbox ssh-config "$SANDBOX_NAME" > "$CONF_FILE" 2>/dev/null
    chmod 600 "$CONF_FILE"

    ssh -T -F "$CONF_FILE" "openshell-${SANDBOX_NAME}" \
      "openclaw agent --agent main --local -m $(printf '%q' "$PROMPT") --session-id $(printf '%q' "$SESSION_ID")"
    ;;

  ollama)
    ollama run "$MODEL_NAME" "$PROMPT"
    ;;

  llamacpp)
    # Expects LLAMACPP_SERVER env or localhost:8080
    LLAMACPP_URL="${LLAMACPP_SERVER:-http://localhost:8080}"
    curl -s "$LLAMACPP_URL/completion" \
      -H "Content-Type: application/json" \
      -d "{\"prompt\": $(printf '%s' "$PROMPT" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'), \"n_predict\": 2048}" \
      | python3 -c "import json,sys; print(json.load(sys.stdin).get('content',''))"
    ;;

  *)
    echo "Unknown MODEL_BACKEND: $MODEL_BACKEND" >&2
    exit 1
    ;;
esac
