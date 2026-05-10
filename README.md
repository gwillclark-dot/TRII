# TRII

A harness for running long-lived agentic CLI sessions as chat-supervised workers.

```
~/projects/<name>/        ← project working dir + CLAUDE.md
       ↕
  tmux session            ← claude --channels (Claude Max)
       ↕
  Discord channel         ← dispatch surface (in/out)
       ↕
  launchd plist           ← scheduled heartbeats
       ↕
  watchdog                ← clears trust prompts, detects silence
```

## Status

**Phase 1 (this commit):** the pre-pivot adapter/NemoClaw stack has been removed; the repo is rebased onto the channels-pattern premise.

**Phase 2 (next):** `trii new <name>` scaffold, daily-digest example, watchdog, warm-keep heartbeat.

The pre-pivot adapter implementation is preserved at the [`legacy-pre-channels`](https://github.com/gwillclark-dot/TRII/tree/legacy-pre-channels) tag. Selected institutional knowledge from the old install path lives in [`docs/legacy-nemoclaw.md`](docs/legacy-nemoclaw.md).

## Profiles

| Profile | Agent CLI | Listener | Status |
|---------|-----------|----------|--------|
| Claude Max | `claude --channels` | Discord plugin (built-in) | v1 — Phase 2 |
| BYO-CLI | codex / gemini / goose / aider | TRII-provided generic listener | v2 — deferred |

## Why this shape

`--channels` is a *pattern*, not a Claude feature. Stripped of branding it's: long-running agentic CLI in tmux + chat channel as dispatch + state files on disk + per-project launchd. TRII productizes the harness around that pattern, leaving the agent CLI choice to the operator.

## License

MIT. See [LICENSE](LICENSE).
