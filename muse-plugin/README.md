# Muse provider

Native CLIProxyAPI C ABI plugin for `muse-spark-1.3`. It uses Meta's Responses API directly and leaves other providers unchanged.

Build on the machine that runs the proxy:

```sh
go test -race ./...
CGO_ENABLED=1 go build -buildmode=c-shared -o /path/to/plugins/muse.so .
```

Use `muse.dylib` on macOS. The proxy must also be built with `CGO_ENABLED=1`. VibeProxy's app build includes the macOS plugin and enables it for a managed local server when there is no existing plugin configuration.

For an existing server, add this to its configuration, preserving other plugin entries:

```yaml
plugins:
  enabled: true
  dir: /path/to/plugins
  configs:
    muse:
      enabled: true
```

Sign in using `muse login`, then connect Muse in VibeProxy. The app imports the saved Meta grant from macOS Keychain into `~/.cli-proxy-api/muse.json` with mode `0600`. Existing credential sync also copies this account to the remote proxy. Disconnect removes the proxy credential, leaving the CLI's Keychain login intact.

The plugin mints an API key from the grant, caches it in memory and renews it once after an upstream 401. The observed grant has no refresh token. A revoked/expired Meta grant requires signing in again and reconnecting Muse. No inference request launches the CLI.

Use `/v1/responses` with model `muse-spark-1.3`. Text, streaming and automatic function-call round trips are verified. Output-token caps are preserved. Forced `tool_choice` is rejected with HTTP 400; image generation and other modalities are not claimed. Requests have a five-minute timeout. Streaming stops when the host rejects a chunk after client cancellation; a stalled upstream is bounded by that timeout.

The app reads subscription usage through the management API and displays Meta's five-hour and weekly remaining percentages and reset times. Unknown quota schemas display unavailable. This is account-wide usage, including Muse CLI activity.
