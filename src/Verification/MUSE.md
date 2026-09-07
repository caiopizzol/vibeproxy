# Muse integration

The native provider is in `muse-plugin/`. Verify it with:

```sh
(cd muse-plugin && go test -race ./...)
python3 src/Verification/muse-plugin-probe.py
```

The native probe uses an isolated proxy and private temporary credential file. It verifies nonstreamed/streamed Responses, output-token limits, a complete automatic tool-call round trip, explicit HTTP 400 for forced tool choice, live subscription usage through management `/api-call`, and absence of the grant from `/auth-files`. The real Keychain login remains unchanged.

Verified contracts on September 7, 2026:

- Keychain service `ai.meta.dev.credentials`, account `meta`, contains `access_token` and a cached `api_key`. The observed grant has no refresh token.
- `POST https://api.meta.ai/muse-code/key`, `Authorization: Bearer <access_token>`, `x-api-version: 1.0.0`, JSON `{}` returns an API key and `base_url: https://api.meta.ai/v1`.
- Subscription fields: `is_subs_active`, `subs_usage.window.{used_percent,window_duration_mins,resets_at}`, `subs_usage.weekly.{used_percent,resets_at}`. The observed short window is 300 minutes; reset times are Unix seconds.
- Minting and inference work without launching the CLI. Unit tests simulate an expired API key and prove one renewal/retry, without removing output caps or injecting image tools.
- Bundled backend 7.2.103 loads the plugin. The NUC's custom 7.2.147 binary was built with CGO disabled and therefore needs rebuilding with CGO enabled. Its exact source is upstream `17a65ee5470fbaf0e22fc219381e6a4ae9e07624` plus PR 5403's Fable 5.1 model-catalog patch.

`MuseQuotaSpec.swift` verifies schema rejection and the management request. Pass `--live` after connecting the account to check usage through the configured NUC tunnel. Reconnecting an expired Meta grant requires `muse login` followed by the app's Connect action; automatic renewal of that grant is not claimed.

Deployment state: app 1.9.0-muse is installed and opened at `/Applications/VibeProxy.app`. The NUC runtime was rebuilt from the source described above with CGO enabled and the Muse plugin installed. All 41 preexisting models survived the restart; Claude and Grok quota calls returned HTTP 200. Connecting the real Muse account to the NUC is pending the user's explicit approval to sync its grant, as required by `~/.agents/remote-nucbox.md`. No Muse credential was added to the synced directory during verification.
