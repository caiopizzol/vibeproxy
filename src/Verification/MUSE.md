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

## Missing usage snapshots

Meta sometimes returns HTTP 200 with an active subscription but omits `subs_usage`. This has recurred after an idle period; a subsequent inference restored the snapshot in observed tests. Lazy window initialization is a hypothesis, not a guaranteed API contract.

VibeProxy now persists only decoded Muse percentages, reset times, and the original observation time. If a later successful response omits or nulls `subs_usage`, the app shows the saved values as **Last known** with their timestamp. It does not infer that a reset restored 100%, and it does not send model requests to obtain quota. Without a prior snapshot it explicitly says Meta has not reported usage yet. Authentication failures and malformed supplied usage remain errors.

Cache identity includes the server origin, auth index, filename, and account email (hashed for the cache filename). The stored payload contains no credentials, raw mint responses, or email. Atomic, serialized writes retain the newer snapshot; corrupt caches are ignored. Account/server changes cannot reuse another account's snapshot.

`MuseQuotaSpec.swift` covers persistence across client recreation, absent/null versus malformed usage, account/server isolation, original timestamps, fresh recovery, auth failures, corrupt files, and older writes. Grok quota regression checks remain passing. The live configured server also passed a quota fetch and persistent-cache round trip on September 11, 2026.
