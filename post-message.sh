#!/bin/bash
# post-message.sh — Send a message to the configured messaging surface
# Usage: post-message.sh <channel-name-or-id> <message>
#
# Resolves logical channel names (e.g. "general") to IDs via channels.json.
# Validates delivery: exits non-zero if message was not confirmed sent.

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
    print('Unknown channel: $CHANNEL', file=sys.stderr)
    sys.exit(1)
" 2>/dev/null) || { echo "ERROR: Unknown channel '$CHANNEL'. Add it to channels.json." >&2; exit 1; }
  CHANNEL="$RESOLVED"
fi

case "$MESSAGE_BACKEND" in
  slack)
    if [ -z "${SLACK_BOT_TOKEN:-}" ]; then
      echo "ERROR: SLACK_BOT_TOKEN not set. Configure it in .env" >&2
      exit 1
    fi

    # Build JSON payload safely
    PAYLOAD=$(python3 -c "
import json, sys
print(json.dumps({'channel': sys.argv[1], 'text': sys.argv[2]}))
" "$CHANNEL" "$MESSAGE")

    # Make request, capture response and HTTP status
    HTTP_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST https://slack.com/api/chat.postMessage \
      -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$PAYLOAD") || {
      echo "ERROR: curl failed (network error or timeout)" >&2
      exit 1
    }

    # Split response body and HTTP status code
    HTTP_CODE=$(echo "$HTTP_RESPONSE" | tail -1)
    RESPONSE_BODY=$(echo "$HTTP_RESPONSE" | sed '$d')

    # Check HTTP status
    if [ "$HTTP_CODE" != "200" ]; then
      echo "ERROR: Slack API returned HTTP $HTTP_CODE" >&2
      echo "$RESPONSE_BODY" >&2
      exit 1
    fi

    # Check for empty/malformed response
    if [ -z "$RESPONSE_BODY" ]; then
      echo "ERROR: Empty response from Slack API" >&2
      exit 1
    fi

    # Validate Slack API response (ok field)
    SLACK_OK=$(python3 -c "
import json, sys
try:
    resp = json.loads(sys.argv[1])
    if resp.get('ok'):
        print('true')
    else:
        err = resp.get('error', 'unknown error')
        print(err, file=sys.stderr)
        print('false')
except (json.JSONDecodeError, KeyError):
    print('malformed response', file=sys.stderr)
    print('false')
" "$RESPONSE_BODY" 2>&1)

    SLACK_ERROR=$(echo "$SLACK_OK" | head -1)
    if [ "$SLACK_ERROR" != "true" ]; then
      echo "ERROR: Slack API returned ok:false — $SLACK_ERROR" >&2
      exit 1
    fi
    ;;

  stdout)
    echo "[$CHANNEL] $MESSAGE"
    ;;

  *)
    echo "ERROR: Unknown MESSAGE_BACKEND '$MESSAGE_BACKEND'. Supported: slack, stdout" >&2
    exit 1
    ;;
esac
