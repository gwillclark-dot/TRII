#!/bin/bash
# refresh-vertex-token.sh — Refresh Google OAuth token for Vertex AI
# Reads credentials from ~/.config/email-wizard/config.json
# Outputs a fresh access token to stdout

set -euo pipefail

CONFIG="$HOME/.config/email-wizard/config.json"

if [ ! -f "$CONFIG" ]; then
  echo "ERROR: $CONFIG not found" >&2
  exit 1
fi

# Extract OAuth fields
CLIENT_ID=$(python3 -c "import json; print(json.load(open('$CONFIG')).get('oauth_client_id',''))")
CLIENT_SECRET=$(python3 -c "import json; print(json.load(open('$CONFIG')).get('oauth_client_secret',''))")
REFRESH_TOKEN=$(python3 -c "import json; print(json.load(open('$CONFIG')).get('oauth_refresh_token',''))")

if [ -z "$REFRESH_TOKEN" ]; then
  echo "ERROR: No refresh token in config" >&2
  exit 1
fi

# Refresh the token
RESPONSE=$(curl -s -X POST https://oauth2.googleapis.com/token \
  -H "Content-Type: application/json" \
  -d "{
    \"client_id\": \"$CLIENT_ID\",
    \"client_secret\": \"$CLIENT_SECRET\",
    \"refresh_token\": \"$REFRESH_TOKEN\",
    \"grant_type\": \"refresh_token\"
  }")

ACCESS_TOKEN=$(echo "$RESPONSE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('access_token',''))")

if [ -z "$ACCESS_TOKEN" ]; then
  echo "ERROR: Token refresh failed" >&2
  exit 1
fi

echo "$ACCESS_TOKEN"
