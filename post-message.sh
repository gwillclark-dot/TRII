#!/bin/bash
# post-message.sh — Send a message to the configured messaging surface
# Usage: post-message.sh <channel-name-or-id> <message>
#
# Resolves logical channel names (e.g. "general") to IDs via channels.json.
# Raw channel IDs (e.g. "CXXXXXXXXXX") are passed through directly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/trii.conf"

# Load .env for tokens (if present)
if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a
  source "$SCRIPT_DIR/.env"
  set +a
fi

CHANNEL="${1:?Usage: post-message.sh <channel-name-or-id> <message>}"
MESSAGE="${2:?Usage: post-message.sh <channel-name-or-id> <message>}"

# Resolve logical channel name to ID via channels.json
if [[ ! "$CHANNEL" =~ ^C[A-Z0-9]+$ ]]; then
  RESOLVED=$(python3 -c "
import json, sys
with open('$SCRIPT_DIR/channels.json') as f:
    channels = json.load(f)
ch = channels.get('$CHANNEL')
if ch:
    print(ch['id'])
else:
    print('', file=sys.stderr)
    sys.exit(1)
" 2>/dev/null) || { echo "Unknown channel: $CHANNEL" >&2; exit 1; }
  CHANNEL="$RESOLVED"
fi

case "$MESSAGE_BACKEND" in
  slack)
    if [ -z "${SLACK_BOT_TOKEN:-}" ]; then
      echo "SLACK_BOT_TOKEN not set" >&2
      exit 1
    fi
    curl -s -X POST https://slack.com/api/chat.postMessage \
      -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$(python3 -c "
import json, sys
print(json.dumps({'channel': '$CHANNEL', 'text': sys.argv[1]}))
" "$MESSAGE")" > /dev/null
    ;;

  stdout)
    echo "[$CHANNEL] $MESSAGE"
    ;;

  *)
    echo "Unknown MESSAGE_BACKEND: $MESSAGE_BACKEND" >&2
    exit 1
    ;;
esac
