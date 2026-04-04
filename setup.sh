#!/bin/bash
# setup.sh — Guided NemoClaw + Ollama + Gemma 4 bootstrap for TRII
#
# This is a one-time setup script, not a runtime dependency.
# After setup, only trii.conf + .env + installed binaries are needed.
#
# Behavior:
# - Detects what's already installed, prints status
# - Installs only with user confirmation (or --non-interactive flag)
# - Never overwrites existing .env, trii.conf, or channels.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NON_INTERACTIVE="${1:-}"

# Colors for status output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
warn() { echo -e "  ${YELLOW}!${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; }

confirm() {
  if [ "$NON_INTERACTIVE" = "--non-interactive" ]; then
    return 0
  fi
  read -rp "  → $1 [y/N] " answer
  [[ "$answer" =~ ^[Yy] ]]
}

echo ""
echo "┌─────────────────────────────────────────┐"
echo "│  TRII Setup                             │"
echo "│  NemoClaw + Ollama + Gemma 4            │"
echo "└─────────────────────────────────────────┘"
echo ""

# ── Step 1: Check prerequisites ────────────────────────────────────

echo "Checking prerequisites..."
MISSING=()

# Node.js
if command -v node &>/dev/null; then
  NODE_VER=$(node --version | sed 's/v//')
  NODE_MAJOR=$(echo "$NODE_VER" | cut -d. -f1)
  if [ "$NODE_MAJOR" -ge 22 ]; then
    ok "Node.js $NODE_VER"
  else
    fail "Node.js $NODE_VER (need 22.16+)"
    MISSING+=("nodejs")
  fi
else
  fail "Node.js not found (need 22.16+)"
  MISSING+=("nodejs")
fi

# npm
if command -v npm &>/dev/null; then
  NPM_VER=$(npm --version)
  ok "npm $NPM_VER"
else
  fail "npm not found"
  MISSING+=("npm")
fi

# Container runtime
CONTAINER_RUNTIME=""
if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
  ok "Docker (running)"
  CONTAINER_RUNTIME="docker"
elif command -v colima &>/dev/null && colima status &>/dev/null 2>&1; then
  ok "Colima (running)"
  CONTAINER_RUNTIME="colima"
else
  if command -v docker &>/dev/null; then
    fail "Docker installed but not running — start it first"
  elif command -v colima &>/dev/null; then
    fail "Colima installed but not running — run: colima start"
  else
    fail "No container runtime (need Docker Desktop or Colima)"
  fi
  MISSING+=("container-runtime")
fi

# Xcode CLI tools (macOS)
if [ "$(uname)" = "Darwin" ]; then
  if xcode-select -p &>/dev/null; then
    ok "Xcode CLI tools"
  else
    fail "Xcode CLI tools not installed — run: xcode-select --install"
    MISSING+=("xcode-cli")
  fi
fi

# Python 3
if command -v python3 &>/dev/null; then
  ok "Python 3 ($(python3 --version 2>&1 | awk '{print $2}'))"
else
  fail "Python 3 not found"
  MISSING+=("python3")
fi

echo ""

if [ ${#MISSING[@]} -gt 0 ]; then
  echo "Missing prerequisites: ${MISSING[*]}"
  echo "Install them and re-run this script."
  exit 1
fi

# ── Step 2: Ollama ─────────────────────────────────────────────────

echo "Checking Ollama..."
if command -v ollama &>/dev/null; then
  ok "Ollama installed"
else
  warn "Ollama not found"
  if confirm "Install Ollama via Homebrew?"; then
    brew install ollama
    ok "Ollama installed"
  else
    echo "  Ollama is required for local model inference."
    echo "  Install manually: https://ollama.com/download"
    exit 1
  fi
fi

# ── Step 3: Pull Gemma 4 ──────────────────────────────────────────

echo ""
echo "Checking Gemma 4 model..."

# Read model name from trii.conf if it exists
if [ -f "$SCRIPT_DIR/trii.conf" ]; then
  source "$SCRIPT_DIR/trii.conf"
fi
TARGET_MODEL="${MODEL_NAME:-gemma4}"

if ollama list 2>/dev/null | grep -q "$TARGET_MODEL"; then
  ok "$TARGET_MODEL already pulled"
else
  warn "$TARGET_MODEL not found in Ollama"
  if confirm "Pull $TARGET_MODEL? (this may take a while)"; then
    ollama pull "$TARGET_MODEL"
    ok "$TARGET_MODEL pulled"
  else
    echo "  You can pull it later: ollama pull $TARGET_MODEL"
  fi
fi

# ── Step 4: NemoClaw ──────────────────────────────────────────────

echo ""
echo "Checking NemoClaw..."
if command -v nemoclaw &>/dev/null; then
  ok "NemoClaw installed"
else
  warn "NemoClaw not found"
  if confirm "Install NemoClaw?"; then
    echo "  Running NemoClaw installer..."
    curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash
    # Source shell config to pick up new PATH entries
    if [ -f "$HOME/.zshrc" ]; then
      source "$HOME/.zshrc" 2>/dev/null || true
    elif [ -f "$HOME/.bashrc" ]; then
      source "$HOME/.bashrc" 2>/dev/null || true
    fi
    if command -v nemoclaw &>/dev/null; then
      ok "NemoClaw installed"
    else
      fail "NemoClaw install completed but 'nemoclaw' not on PATH"
      echo "  Try: source ~/.zshrc  (or ~/.bashrc)"
      echo "  Then re-run this script."
      exit 1
    fi
  else
    echo "  You can install later: curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash"
  fi
fi

# ── Step 5: Onboard sandbox ──────────────────────────────────────

echo ""
SANDBOX="${SANDBOX_NAME:-trii}"

if command -v nemoclaw &>/dev/null; then
  echo "Checking NemoClaw sandbox '$SANDBOX'..."
  if nemoclaw "$SANDBOX" status &>/dev/null 2>&1; then
    ok "Sandbox '$SANDBOX' exists and is running"
  else
    warn "Sandbox '$SANDBOX' not found"
    if confirm "Create sandbox '$SANDBOX' with Ollama + $TARGET_MODEL?"; then
      NEMOCLAW_PROVIDER=ollama \
        NEMOCLAW_MODEL="$TARGET_MODEL" \
        nemoclaw onboard --non-interactive --name "$SANDBOX"
      ok "Sandbox '$SANDBOX' created"
    else
      echo "  You can create it later:"
      echo "  NEMOCLAW_PROVIDER=ollama NEMOCLAW_MODEL=$TARGET_MODEL nemoclaw onboard"
    fi
  fi

  # ── Step 5b: Slack network policy (optional, backend-aware) ────
  if [ -f "$SCRIPT_DIR/trii.conf" ]; then
    source "$SCRIPT_DIR/trii.conf"
  fi
  if [ "${MESSAGE_BACKEND:-}" = "slack" ]; then
    echo ""
    echo "Slack messaging detected in trii.conf."
    echo "NemoClaw has a Slack network policy preset that allows api.slack.com egress."
    if confirm "Apply Slack network policy to sandbox '$SANDBOX'?"; then
      # The preset is bundled with NemoClaw's blueprint
      echo "  Note: Apply via 'openshell policy add' once the sandbox is connected."
      echo "  See: nemoclaw-blueprint/policies/presets/slack.yaml"
      warn "Manual step — apply when connected to sandbox"
    fi
  fi
fi

# ── Step 6: Configure .env ────────────────────────────────────────

echo ""
echo "Checking configuration files..."

if [ -f "$SCRIPT_DIR/.env" ]; then
  ok ".env exists (not overwriting)"
else
  if [ -f "$SCRIPT_DIR/.env.example" ]; then
    if confirm "Create .env from .env.example?"; then
      cp "$SCRIPT_DIR/.env.example" "$SCRIPT_DIR/.env"
      ok ".env created — edit it with your Slack bot token"
    fi
  fi
fi

if [ -f "$SCRIPT_DIR/trii.conf" ]; then
  ok "trii.conf exists (not overwriting)"
else
  warn "trii.conf not found — the repo may be incomplete"
fi

if [ -f "$SCRIPT_DIR/channels.json" ]; then
  ok "channels.json exists (not overwriting)"
else
  warn "channels.json not found — the repo may be incomplete"
fi

# ── Step 7: Smoke test ────────────────────────────────────────────

echo ""
echo "Running smoke tests..."

# Test messaging adapter (stdout mode — no Slack needed)
STDOUT_RESULT=$(MESSAGE_BACKEND=stdout "$SCRIPT_DIR/post-message.sh" "general" "TRII setup smoke test" 2>&1) || true
if echo "$STDOUT_RESULT" | grep -q "TRII setup smoke test"; then
  ok "post-message.sh (stdout mode)"
else
  fail "post-message.sh (stdout mode): $STDOUT_RESULT"
fi

# Test agent adapter (only if backend is available)
if [ -f "$SCRIPT_DIR/trii.conf" ]; then
  source "$SCRIPT_DIR/trii.conf"
fi
case "${MODEL_BACKEND:-}" in
  ollama)
    if command -v ollama &>/dev/null && ollama list 2>/dev/null | grep -q "${MODEL_NAME:-gemma4}"; then
      echo "  Testing run-agent.sh (this may take a moment)..."
      AGENT_RESULT=$("$SCRIPT_DIR/run-agent.sh" "Reply with exactly: setup ok" "smoke-test" 2>/dev/null) || true
      if [ -n "$AGENT_RESULT" ]; then
        ok "run-agent.sh (ollama/$MODEL_NAME)"
      else
        warn "run-agent.sh returned empty response"
      fi
    else
      warn "Skipping agent smoke test (model not available yet)"
    fi
    ;;
  nemoclaw)
    if command -v nemoclaw &>/dev/null && nemoclaw "${SANDBOX_NAME:-trii}" status &>/dev/null 2>&1; then
      echo "  Testing run-agent.sh (this may take a moment)..."
      AGENT_RESULT=$("$SCRIPT_DIR/run-agent.sh" "Reply with exactly: setup ok" "smoke-test" 2>/dev/null) || true
      if [ -n "$AGENT_RESULT" ]; then
        ok "run-agent.sh (nemoclaw/$SANDBOX_NAME)"
      else
        warn "run-agent.sh returned empty response"
      fi
    else
      warn "Skipping agent smoke test (sandbox not running)"
    fi
    ;;
  *)
    warn "Skipping agent smoke test (MODEL_BACKEND not configured)"
    ;;
esac

# ── Done ──────────────────────────────────────────────────────────

echo ""
echo "┌─────────────────────────────────────────┐"
echo "│  Setup complete                         │"
echo "└─────────────────────────────────────────┘"
echo ""
echo "Next steps:"
echo "  1. Edit .env with your Slack bot token"
echo "  2. Edit channels.json with your Slack channel IDs"
echo "  3. Add projects to PROJECTS array in trii-run.sh"
echo "  4. Test: MESSAGE_BACKEND=stdout ./post-message.sh general 'hello'"
echo "  5. Test: ./run-agent.sh 'Reply with one sentence: setup ok'"
echo "  6. First run: bash trii-run.sh"
echo ""
