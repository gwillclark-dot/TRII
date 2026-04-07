#!/bin/bash
# run-icons-digest.sh — Run the icons-agent daily digest inside the NemoClaw sandbox
# Scheduled via launchd (com.trii.icons-digest.plist)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGFILE="$SCRIPT_DIR/session-log/icons-digest-$(date +%Y-%m-%d).log"

echo "=== Icons digest starting at $(date) ===" > "$LOGFILE"

# Get SSH config for sandbox
CONF_DIR=$(mktemp -d)
CONF_FILE="$CONF_DIR/config"
trap 'rm -f "$CONF_FILE"; rmdir "$CONF_DIR" 2>/dev/null' EXIT

if ! openshell sandbox ssh-config my-assistant > "$CONF_FILE" 2>/dev/null; then
  echo "ERROR: Sandbox not running" >> "$LOGFILE"
  exit 1
fi
chmod 600 "$CONF_FILE"

# Run the digest script inside the sandbox
ssh -T -F "$CONF_FILE" openshell-my-assistant \
  'export PATH="/sandbox/.local/bin:$PATH" && export HOME=/sandbox && export SSL_CERT_FILE=/etc/openshell-tls/ca-bundle.pem && cd /sandbox/icons-agent && bash send_icons_daily_digest.sh' \
  >> "$LOGFILE" 2>&1

EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
  echo "=== Icons digest completed at $(date) ===" >> "$LOGFILE"
else
  echo "=== Icons digest FAILED (exit $EXIT_CODE) at $(date) ===" >> "$LOGFILE"
fi
