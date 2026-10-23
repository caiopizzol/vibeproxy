# agent-quota

Read Claude subscription quota through an existing CLIProxyAPI. Requires Bun; macOS also requires the configured `nucbox` SSH host. No VibeProxy app or new daemon needs to run on the client.

```sh
agent-quota
agent-quota --provider claude --json
```

macOS forwards the command to the proxy host over SSH. Linux (or `--local`) queries `http://127.0.0.1:18317/v0/management`, reading `MANAGEMENT_PASSWORD` from `~/.config/vibeproxy-nucbox/management.env`. Credentials stay on the proxy host. Accounts have opaque stable identifiers; disabled accounts are listed without querying them.

Output preserves each subscription window and model/surface scope. `status: ok` means quota was retrieved, not that the proxy can route a model request. Check `proxyStatus`, `unavailable`, and `nextRetryAfter` separately. Remaining percentages cannot be summed across accounts or windows. Paid overage is excluded. No provider or account is automatically selected.

Exit codes: 0 = quota retrieved for all enabled accounts; 2 = incomplete quota or no usable quota observations; 1 = command, credentials, or transport failure. Unknown quota is never represented as zero. Requests share a 25-second deadline; SSH is limited to 35 seconds.

Run `bun install` and `bun run check` here. Run `./install.sh` on each machine to copy the runtime into `~/.local/share/agent-quota/` and install the command in `~/.local/bin`. The wrapper uses Bun from PATH (falling back to `~/.bun/bin/bun`) with automatic `.env` loading disabled.
