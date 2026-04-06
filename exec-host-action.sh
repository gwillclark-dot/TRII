#!/bin/bash
# exec-host-action.sh — Execute a whitelisted host-side action
# Usage: exec-host-action.sh <action-name> <channel>
#
# Looks up action in host-actions.conf. Rejects unknown or malformed names.
# Posts result to Slack as a follow-up message.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/trii.conf"

ACTION="${1:?Usage: exec-host-action.sh <action-name> <channel>}"
CHANNEL="${2:?Usage: exec-host-action.sh <action-name> <channel>}"
CONF="$SCRIPT_DIR/host-actions.conf"

# Validate action name: lowercase alphanumeric + hyphens only
if [[ ! "$ACTION" =~ ^[a-z0-9][-a-z0-9]*$ ]]; then
  echo "REJECTED: invalid action name '$ACTION'" >&2
  exit 1
fi

# Look up action in registry (skip comments and blank lines)
COMMAND=$(grep "^${ACTION}=" "$CONF" 2>/dev/null | head -1 | cut -d= -f2-)

if [ -z "$COMMAND" ]; then
  "$SCRIPT_DIR/post-message.sh" "$CHANNEL" \
    "⚠️ Unknown host action: \`$ACTION\`. Not in whitelist." 2>/dev/null || true
  exit 1
fi

echo "Executing host action: $ACTION" >&2

# Execute with 30s timeout (perl fallback for macOS which lacks timeout)
if command -v timeout &>/dev/null; then
  OUTPUT=$(timeout 30 bash -c "$COMMAND" 2>&1) && EXIT=0 || EXIT=$?
else
  OUTPUT=$(perl -e 'alarm 30; exec @ARGV' bash -c "$COMMAND" 2>&1) && EXIT=0 || EXIT=$?
fi
OUTPUT_SHORT=$(echo "$OUTPUT" | tail -5 | head -c 500)

if [ $EXIT -eq 0 ]; then
  "$SCRIPT_DIR/post-message.sh" "$CHANNEL" \
    "🔧 Host action \`$ACTION\`: success.${OUTPUT_SHORT:+
\`\`\`${OUTPUT_SHORT}\`\`\`}" 2>/dev/null || true
else
  "$SCRIPT_DIR/post-message.sh" "$CHANNEL" \
    "⚠️ Host action \`$ACTION\`: failed (exit $EXIT).${OUTPUT_SHORT:+
\`\`\`${OUTPUT_SHORT}\`\`\`}" 2>/dev/null || true
fi
