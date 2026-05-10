# Legacy NemoClaw notes

> Preserved from the pre-`legacy-pre-channels` adapter implementation. None of this applies to the current channels-pattern harness; kept here as institutional knowledge in case a future profile reuses NemoClaw or Ollama-in-sandbox.
>
> For the full pre-pivot install procedure, check out the [`legacy-pre-channels`](https://github.com/gwillclark-dot/TRII/tree/legacy-pre-channels) tag.

## APFS free-space lie

`df -h /` lies on macOS APFS. Use `diskutil info / | grep "Container Free Space"` for the real number. Sandbox builds need ~12GB free.

## sandbox-base image: missing `sandbox` user

The published `ghcr.io/nvidia/nemoclaw/sandbox-base:latest` image may be missing the `sandbox` user, causing `USER sandbox` to fail with `unable to find user sandbox`. Fix: rebuild locally from `~/.nemoclaw/source`.

Before building, append Playwright/Chromium dependencies to `Dockerfile.base`:

```
libasound2 libatk-bridge2.0-0 libatk1.0-0 libatspi2.0-0 \
libcairo2 libcups2 libdbus-1-3 libgbm1 libglib2.0-0 \
libnspr4 libnss3 libpango-1.0-0 libx11-6 libxcb1 \
libxcomposite1 libxdamage1 libxext6 libxfixes3 \
libxkbcommon0 libxrandr2
```

Without these, `playwright install chromium` succeeds but Chromium won't launch — and the sandbox can't `apt-get install` at runtime (no root).

```bash
cd ~/.nemoclaw/source
docker build -f Dockerfile.base -t ghcr.io/nvidia/nemoclaw/sandbox-base:latest .
```

## `setsid` shim for macOS

macOS doesn't have GNU `setsid`. The pre-pivot `bin/setsid` shim used Perl's POSIX module to provide process-group isolation for watchdog kills.

## Google API network policy: TLS termination breaks compiled binaries

Two non-obvious requirements when adding Google API egress to a NemoClaw sandbox network policy:

1. **`access: full`** (raw CONNECT tunnel), not `protocol: rest` with `tls: terminate`. Compiled binaries like `gws` (Rust) bring their own TLS stack and reject the proxy's re-signed certificates.
2. **Wildcard binary paths**: `/usr/bin/python3*`, not `/usr/bin/python3`. The proxy resolves symlinks before checking — `/usr/bin/python3` is a symlink to `/usr/bin/python3.11`, and the exact path doesn't match without a wildcard.

Without the wildcard, `curl` works but Python gets `403 Forbidden`. The PyPI preset (which works for `pip install`) uses `/usr/bin/python3*` — follow that pattern.

```yaml
network_policies:
  google_apis:
    name: google_apis
    endpoints:
    - host: www.googleapis.com
      port: 443
      access: full
    - host: gmail.googleapis.com
      port: 443
      access: full
    - host: oauth2.googleapis.com
      port: 443
      access: full
    - host: accounts.google.com
      port: 443
      access: full
    binaries:
    - path: /usr/bin/python3*
    - path: /usr/local/bin/python3*
    - path: /sandbox/.local/bin/python*
```

## Injecting OAuth credentials into the sandbox

OAuth tokens expire after ~1 hour. The pre-pivot pattern refreshed the token on the host and tar-piped the new config into the sandbox before each agent run. `scp` doesn't work (no sftp-server in sandbox); use tar-over-ssh instead.

## Slack two-token gotcha

Pre-pivot Slack listener required *both* tokens:

- `xoxb-...` (Bot User OAuth Token) — for posting messages
- `xapp-...` (App-Level Token) — for Socket Mode listener

The bot user must be created (App Home → Messages Tab) BEFORE installing to workspace, else "doesn't have a bot user to install."
