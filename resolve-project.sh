#!/bin/bash
# resolve-project.sh — Shared project name → directory resolver
# Usage: source this file, then call resolve_project_dir <name>
#
# Returns the absolute path to the project's working directory.
# Falls back to TRII_HOME if the project directory doesn't exist.

resolve_project_dir() {
  local PROJECT="$1"
  local BASE="${TRII_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

  case "$PROJECT" in
    trii|orchestrator) echo "$BASE" ;;
    *)
      # Check for exact subdirectory match first, then examples/
      if [ -d "$BASE/$PROJECT" ]; then
        echo "$BASE/$PROJECT"
      elif [ -d "$BASE/examples/$PROJECT" ]; then
        echo "$BASE/examples/$PROJECT"
      else
        # Fall back to TRII root
        echo "$BASE" >&2
        echo "Warning: no directory found for project '$PROJECT', using TRII root" >&2
        echo "$BASE"
      fi
      ;;
  esac
}
