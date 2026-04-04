#!/usr/bin/env python3
"""TRII Slack Socket Mode listener — bridges Slack messages into dispatch/."""

import json
import os
import re
import signal
import subprocess
import sys
import time
from collections import deque
from pathlib import Path
from urllib.request import Request, urlopen

import websocket

SCRIPT_DIR = Path(__file__).resolve().parent
DISPATCH_DIR = SCRIPT_DIR / "dispatch"
ENV_FILE = SCRIPT_DIR / ".env"

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

def load_env():
    """Load .env file into os.environ."""
    if ENV_FILE.exists():
        for line in ENV_FILE.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip())

load_env()

APP_TOKEN = os.environ.get("SLACK_APP_TOKEN", "")
BOT_TOKEN = os.environ.get("SLACK_BOT_TOKEN", "")

if not APP_TOKEN.startswith("xapp-"):
    sys.exit("SLACK_APP_TOKEN (xapp-...) not set in .env")
if not BOT_TOKEN.startswith("xoxb-"):
    sys.exit("SLACK_BOT_TOKEN (xoxb-...) not set in .env")

# ---------------------------------------------------------------------------
# Slack API helpers
# ---------------------------------------------------------------------------

def slack_api(method, token, payload=None):
    """Call a Slack Web API method. Returns parsed JSON."""
    url = f"https://slack.com/api/{method}"
    data = json.dumps(payload).encode() if payload else None
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json; charset=utf-8",
    }
    req = Request(url, data=data, headers=headers, method="POST")
    with urlopen(req, timeout=10) as resp:
        return json.loads(resp.read())

def get_wss_url():
    """Get a Socket Mode WebSocket URL."""
    r = slack_api("apps.connections.open", APP_TOKEN)
    if not r.get("ok"):
        sys.exit(f"apps.connections.open failed: {r.get('error')}")
    return r["url"]

def get_bot_user_id():
    """Get the bot's own user ID (to detect @mentions)."""
    r = slack_api("auth.test", BOT_TOKEN)
    if not r.get("ok"):
        sys.exit(f"auth.test failed: {r.get('error')}")
    return r["user_id"]

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

KNOWN_PROJECTS = ["GWS_CLI", "KNOWLEDGE_CLI", "Conductor_CLI"]

def detect_project(text):
    """Try to detect a project name from the task text."""
    text_lower = text.lower()
    for p in KNOWN_PROJECTS:
        if p.lower() in text_lower:
            return p
    return "trii"

def write_dispatch(task, channel):
    """Write a dispatch JSON file for the existing dispatch-watcher."""
    DISPATCH_DIR.mkdir(exist_ok=True)
    project = detect_project(task)
    ts = int(time.time() * 1000)
    payload = {"project": project, "task": task, "channel": channel}
    path = DISPATCH_DIR / f"{ts}-slack.json"
    path.write_text(json.dumps(payload, indent=2))
    print(f"[dispatch] wrote {path.name}: {task[:80]}", flush=True)
    return path

def send_ack_message(channel, text="Dispatched. Working on it."):
    """Send an immediate acknowledgment via post-message.sh."""
    try:
        subprocess.run(
            [str(SCRIPT_DIR / "post-message.sh"), channel, text],
            timeout=10, capture_output=True,
        )
    except Exception as e:
        print(f"[warn] ack failed: {e}", file=sys.stderr, flush=True)

def kick_dispatch_watcher():
    """Run dispatch-watcher.sh if no other instance is running."""
    lock = SCRIPT_DIR / ".dispatch-lock"
    if lock.exists():
        return
    try:
        subprocess.Popen(
            ["bash", str(SCRIPT_DIR / "dispatch-watcher.sh")],
            cwd=str(SCRIPT_DIR),
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
    except Exception as e:
        print(f"[warn] kick dispatch failed: {e}", file=sys.stderr, flush=True)

# ---------------------------------------------------------------------------
# Event handling
# ---------------------------------------------------------------------------

SEEN = deque(maxlen=100)

def handle_envelope(ws, raw):
    """Process a Socket Mode envelope."""
    try:
        envelope = json.loads(raw)
    except json.JSONDecodeError:
        return

    eid = envelope.get("envelope_id")
    if not eid:
        return

    # Acknowledge immediately (Slack requires this within 3s)
    ws.send(json.dumps({"envelope_id": eid}))

    # Dedup
    if eid in SEEN:
        return
    SEEN.append(eid)

    etype = envelope.get("type")
    if etype != "events_api":
        return

    event = envelope.get("payload", {}).get("event", {})
    event_type = event.get("type")

    # Skip bot messages, edits, and non-message events
    if event.get("bot_id") or event.get("subtype"):
        return
    if event_type not in ("app_mention", "message"):
        return
    # For regular messages, only handle DMs
    if event_type == "message" and event.get("channel_type") != "im":
        return

    text = event.get("text", "").strip()
    channel = event.get("channel", "")

    if not text or not channel:
        return

    # Strip @mention and normalize whitespace
    text = re.sub(r"<@[A-Z0-9]+>\s*", "", text).strip()
    text = re.sub(r"\s+", " ", text)  # collapse newlines and extra spaces
    if not text:
        return

    print(f"[event] {event_type} in {channel}: {text[:80]}", flush=True)

    write_dispatch(text, channel)
    send_ack_message(channel)
    kick_dispatch_watcher()

# ---------------------------------------------------------------------------
# Main loop with reconnection
# ---------------------------------------------------------------------------

BOT_ID = None
BACKOFF = [5, 10, 20, 40, 60]
RUNNING = True

def shutdown(sig, frame):
    global RUNNING
    print(f"\n[shutdown] signal {sig}, exiting.", flush=True)
    RUNNING = False

signal.signal(signal.SIGTERM, shutdown)
signal.signal(signal.SIGINT, shutdown)

def main():
    global BOT_ID
    BOT_ID = get_bot_user_id()
    print(f"[init] bot user: {BOT_ID}", flush=True)

    attempt = 0
    while RUNNING:
        try:
            url = get_wss_url()
            print(f"[ws] connecting...", flush=True)
            ws = websocket.WebSocket()
            ws.settimeout(30)
            ws.connect(url)
            print(f"[ws] connected.", flush=True)
            attempt = 0

            while RUNNING:
                try:
                    raw = ws.recv()
                    if raw:
                        handle_envelope(ws, raw)
                except websocket.WebSocketTimeoutException:
                    continue
                except websocket.WebSocketConnectionClosedException:
                    print("[ws] connection closed, reconnecting...", flush=True)
                    break

        except Exception as e:
            delay = BACKOFF[min(attempt, len(BACKOFF) - 1)]
            print(f"[ws] error: {e}. Retrying in {delay}s...", file=sys.stderr, flush=True)
            attempt += 1
            time.sleep(delay)

    print("[shutdown] done.", flush=True)

if __name__ == "__main__":
    main()
