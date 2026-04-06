#!/usr/bin/env python3
"""TRII Gemini Agent — host-native tool-calling agent using Gemini API.

Runs directly on the host (no sandbox), so it has full access to all CLIs
(dspi, nb, gws, email, git, python, etc.) and the local filesystem.
"""

import json
import os
import subprocess
import sys
from pathlib import Path
from urllib.request import Request, urlopen

SCRIPT_DIR = Path(__file__).resolve().parent
ENV_FILE = SCRIPT_DIR / ".env"
PROJECTS_DIR = Path.home() / "Desktop" / "Projects.nosync"
MAX_ITERATIONS = 15
CMD_TIMEOUT = 60

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

def load_env():
    if ENV_FILE.exists():
        for line in ENV_FILE.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip())

load_env()

API_KEY = os.environ.get("GEMINI_API_KEY", "")
if not API_KEY:
    sys.exit("GEMINI_API_KEY not set in .env")

API_URL = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"

# ---------------------------------------------------------------------------
# Tool definitions (OpenAI function calling format)
# ---------------------------------------------------------------------------

TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "run_command",
            "description": "Execute a shell command on the host. Has access to all installed CLIs: dspi, nb, gws, email, git, python3, node, etc. Commands run with a 60s timeout.",
            "parameters": {
                "type": "object",
                "properties": {
                    "command": {"type": "string", "description": "Shell command to execute"},
                    "workdir": {"type": "string", "description": "Working directory (default: ~/Desktop/Projects.nosync)"},
                },
                "required": ["command"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "read_file",
            "description": "Read a file's contents. Use absolute paths or paths relative to ~/Desktop/Projects.nosync/.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "File path to read"},
                },
                "required": ["path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "write_file",
            "description": "Write content to a file. Creates parent directories if needed.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "File path to write"},
                    "content": {"type": "string", "description": "Content to write"},
                },
                "required": ["path", "content"],
            },
        },
    },
]

# ---------------------------------------------------------------------------
# Tool execution
# ---------------------------------------------------------------------------

def exec_run_command(command: str, workdir: str = "") -> str:
    cwd = workdir or str(PROJECTS_DIR)
    cwd = os.path.expanduser(cwd)
    try:
        r = subprocess.run(
            command, shell=True, capture_output=True, text=True,
            timeout=CMD_TIMEOUT, cwd=cwd,
        )
        output = r.stdout
        if r.stderr:
            output += f"\n[stderr]: {r.stderr}"
        if r.returncode != 0:
            output += f"\n[exit code: {r.returncode}]"
        return output[:8000] or "(no output)"
    except subprocess.TimeoutExpired:
        return f"[error: command timed out after {CMD_TIMEOUT}s]"
    except Exception as e:
        return f"[error: {e}]"


def exec_read_file(path: str) -> str:
    path = os.path.expanduser(path)
    try:
        content = Path(path).read_text()
        return content[:8000]
    except Exception as e:
        return f"[error: {e}]"


def exec_write_file(path: str, content: str) -> str:
    path = os.path.expanduser(path)
    try:
        p = Path(path)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content)
        return f"Written {len(content)} bytes to {path}"
    except Exception as e:
        return f"[error: {e}]"


TOOL_HANDLERS = {
    "run_command": lambda args: exec_run_command(args.get("command", ""), args.get("workdir", "")),
    "read_file": lambda args: exec_read_file(args.get("path", "")),
    "write_file": lambda args: exec_write_file(args.get("path", ""), args.get("content", "")),
}

# ---------------------------------------------------------------------------
# Gemini API
# ---------------------------------------------------------------------------

def chat(messages: list) -> dict:
    payload = {
        "model": "gemini-2.5-flash",
        "messages": messages,
        "tools": TOOLS,
        "max_tokens": 4096,
    }
    data = json.dumps(payload).encode()
    headers = {
        "Authorization": f"Bearer {API_KEY}",
        "Content-Type": "application/json",
    }
    req = Request(API_URL, data=data, headers=headers, method="POST")
    with urlopen(req, timeout=120) as resp:
        return json.loads(resp.read())

# ---------------------------------------------------------------------------
# Session persistence
# ---------------------------------------------------------------------------

SESSION_DIR = SCRIPT_DIR / "sessions"

SYSTEM_PROMPT = """You are TRII — an autonomous technical operator running on the host machine.
You have direct access to all installed CLI tools: dspi, nb, gws, email, git, python3, node, etc.
Projects are at ~/Desktop/Projects.nosync/ (GWS_CLI, KNOWLEDGE_CLI, Conductor_CLI, TRII, etc.).

Rules:
- Use tools to execute commands and read files. Do not describe what you would do — do it.
- Output only the final result. No step-by-step narration.
- Keep your final response under 500 words.
- If a command fails, try to diagnose and fix it before giving up."""


def load_session(session_id: str) -> list:
    """Load conversation history from disk."""
    SESSION_DIR.mkdir(exist_ok=True)
    path = SESSION_DIR / f"{session_id}.json"
    if path.exists():
        try:
            return json.loads(path.read_text())
        except (json.JSONDecodeError, OSError):
            pass
    return [{"role": "system", "content": SYSTEM_PROMPT}]


def save_session(session_id: str, messages: list):
    """Save conversation history to disk. Keep last 50 messages to prevent unbounded growth."""
    SESSION_DIR.mkdir(exist_ok=True)
    # Always keep system prompt + last 49 messages
    if len(messages) > 50:
        messages = [messages[0]] + messages[-49:]
    path = SESSION_DIR / f"{session_id}.json"
    path.write_text(json.dumps(messages, default=str))


def clear_session(session_id: str):
    """Delete a session file."""
    path = SESSION_DIR / f"{session_id}.json"
    path.unlink(missing_ok=True)


# ---------------------------------------------------------------------------
# Agent loop
# ---------------------------------------------------------------------------

def run(prompt: str, session_id: str = "default"):
    messages = load_session(session_id)
    messages.append({"role": "user", "content": prompt})

    for i in range(MAX_ITERATIONS):
        try:
            resp = chat(messages)
        except Exception as e:
            print(f"[agent error: {e}]", file=sys.stderr)
            break

        choice = resp.get("choices", [{}])[0]
        msg = choice.get("message", {})
        finish = choice.get("finish_reason", "")

        # If model returns text (no tool calls), we're done
        tool_calls = msg.get("tool_calls")
        if not tool_calls or finish == "stop":
            text = msg.get("content", "")
            messages.append({"role": "assistant", "content": text})
            save_session(session_id, messages)
            if text:
                print(text)
            break

        # Execute tool calls
        messages.append(msg)
        for tc in tool_calls:
            fn_name = tc["function"]["name"]
            try:
                fn_args = json.loads(tc["function"]["arguments"])
            except json.JSONDecodeError:
                fn_args = {}

            handler = TOOL_HANDLERS.get(fn_name)
            if handler:
                print(f"[tool] {fn_name}: {json.dumps(fn_args)[:100]}", file=sys.stderr, flush=True)
                result = handler(fn_args)
            else:
                result = f"[error: unknown tool '{fn_name}']"

            messages.append({
                "role": "tool",
                "tool_call_id": tc["id"],
                "content": result,
            })
    else:
        print("[agent: max iterations reached]", file=sys.stderr)

    save_session(session_id, messages)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("Usage: gemini-agent.py <prompt> [session-id]")
    session = sys.argv[2] if len(sys.argv) > 2 else "default"
    run(sys.argv[1], session)
