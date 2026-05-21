# Provider-Specific Cache Rate Spec

## Status
Draft

## Owner
Engineering

## Summary

The admin usage dashboard currently reports a single aggregate cache read count and cache hit ratio across all upstream providers. This is misleading in a multi-provider gateway because Anthropic (Claude) and Codex use different caching semantics, return different usage fields, and can have materially different cache behavior.

This spec adds provider-specific cache metrics so the system can report:

- overall cache hit ratio
- Claude/Anthropic cache hit ratio
- Codex cache hit ratio

The implementation will update the usage aggregation model to persist `provider` alongside `email` and `model`, expose provider breakdowns from `/admin/api/usage`, and show provider-specific cache ratios in the admin UI.

## Motivation

### Problem

Today the admin dashboard computes:

- `cache_read_tokens = sum(cache_read_input_tokens)` across all usage rows
- `cache_hit_ratio = cache_read_tokens / input_tokens`

This merges usage from:

- Anthropic / Claude requests, which expose cache creation and cache read fields
- Codex / OpenAI-style requests, which expose cached input tokens through a different upstream shape

As a result:

- a single provider with good cache behavior can mask poor cache behavior from the other provider
- cache regressions are harder to diagnose
- cost optimization decisions are less actionable
- the dashboard implies a uniform cache mechanism when none exists

### Why this matters

Provider-level cache metrics are operationally useful because:

- prompt structure optimizations often differ by provider
- routing/session affinity issues can affect one provider but not another
- cache discounts and retention behavior differ by provider
- debugging a drop in cache efficiency requires knowing which provider regressed

## Goals

- Record usage stats with provider granularity
- Preserve current overall usage summary semantics
- Add provider-specific usage breakdowns for Anthropic and Codex
- Show provider-specific cache hit ratios in admin UI
- Keep implementation simple by **not** supporting old persisted usage rows without provider data

## Non-Goals

- No migration or compatibility layer for historical usage stats without provider
- No backfill or inference of provider from old `usage_total.dets` / `usage_daily.dets`
- No per-account cache rate dashboard changes in this iteration
- No provider-specific cost estimation changes in this iteration
- No additional cache dimensions such as cache mode, TTL bucket, session key, or endpoint

## Decision: No Historical Compatibility

This feature intentionally does **not** support historical persisted usage records created before `provider` becomes part of the usage key.

Implications:

- Existing DETS usage files should be treated as incompatible with the new schema
- On deployment, operators may lose previous aggregated usage history unless they manually preserve and transform it outside the app
- The application does not attempt to infer provider from model names for old records

Rationale:

- avoids schema complexity and migration logic
- avoids incorrect attribution of historical rows
- keeps implementation small and predictable
- acceptable because usage stats are an admin convenience, not a billing source of truth

## Current Behavior

### Request recording

Successful requests eventually call `Manager.record_success/4`, which forwards usage data into `UsageStats.record/5` using:

- `email`
- `model`
- `usage`

The usage stats storage currently aggregates by:

- total key: `{email, model}`
- daily key: `{date, email, model}`

### Admin summary

`/admin/api/usage` returns:

- `summary`
- `totals`
- `daily`

`summary.cache_hit_ratio` is currently computed from all rows combined.

## Proposed Design

## Data Model Changes

### UsageStats keys

Change aggregate keys from:

- totals: `{email, model}`
- daily: `{date, email, model}`

To:

- totals: `{provider, email, model}`
- daily: `{date, provider, email, model}`

### Provider value

Persist provider as a lowercase string:

- `"anthropic"`
- `"codex"`

Future providers may be added later without changing the structure.

### Usage row shape

Rows returned by `UsageStats.totals/1` and `UsageStats.daily/1` should include:

- `provider`
- `email`
- `model`
- existing token counters and request counters

Example total row:

```elixir
%{
  provider: "anthropic",
  email: "user@example.com",
  model: "claude-sonnet-4-6",
  requests: 12,
  input_tokens: 12000,
  output_tokens: 3400,
  cache_creation_input_tokens: 5000,
  cache_creation_5m_tokens: 2000,
  cache_creation_1h_tokens: 3000,
  cache_read_input_tokens: 8000,
  reasoning_output_tokens: 0,
  total_duration_ms: 12345,
  last_at: "2026-05-21T00:00:00Z"
}
```

## Recording Flow Changes

### Manager API flow

Wherever `Manager.record_success/4` is called for successful model requests, the caller must pass both:

- `model`
- `provider`

Recommended provider source:

```elixir
account.provider || account.token.provider || "anthropic"
```

### UsageStats record signature

Change from:

```elixir
UsageStats.record(server, email, model, usage, opts \\ [])
```

To:

```elixir
UsageStats.record(server, provider, email, model, usage, opts \\ [])
```

### Manager internal helper

`record_usage_stats/3` should require a non-empty provider before persisting a usage row.

If provider is missing, the helper may fall back to `"anthropic"`, but the preferred path is that all callers always pass provider explicitly.

## API Changes

## GET /admin/api/usage

### Existing response contract to preserve

Keep these fields:

```json
{
  "summary": {
    "requests": 10,
    "total_tokens": 1000,
    "today_tokens": 250,
    "cache_read_tokens": 300,
    "cache_hit_ratio": 0.3,
    "model_count": 4
  },
  "totals": [...],
  "daily": [...],
  "generated_at": "..."
}
```

### New summary field

Add `summary.provider_breakdown`:

```json
{
  "summary": {
    "requests": 10,
    "total_tokens": 1000,
    "today_tokens": 250,
    "cache_read_tokens": 300,
    "cache_hit_ratio": 0.3,
    "model_count": 4,
    "provider_breakdown": {
      "anthropic": {
        "requests": 6,
        "total_tokens": 700,
        "input_tokens": 500,
        "cache_read_tokens": 200,
        "cache_hit_ratio": 0.4,
        "model_count": 2
      },
      "codex": {
        "requests": 4,
        "total_tokens": 300,
        "input_tokens": 250,
        "cache_read_tokens": 100,
        "cache_hit_ratio": 0.4,
        "model_count": 2
      }
    }
  }
}
```

### Totals and daily rows

Add `provider` to every `totals` and `daily` row.

Example:

```json
{
  "provider": "codex",
  "email": "codex-user@example.com",
  "model": "gpt-5.4-mini",
  "requests": 3,
  "input_tokens": 100,
  "output_tokens": 40,
  "cache_read_input_tokens": 20,
  "cache_creation_input_tokens": 0,
  "total_tokens": 140
}
```

## Metric Definitions

### Overall cache hit ratio

```text
cache_hit_ratio = total cache_read_input_tokens / total input_tokens
```

### Provider cache hit ratio

Same formula, but computed from rows filtered by provider:

```text
anthropic.cache_hit_ratio = anthropic.cache_read_input_tokens / anthropic.input_tokens
codex.cache_hit_ratio = codex.cache_read_input_tokens / codex.input_tokens
```

### Total tokens

Continue using existing definition:

```text
total_tokens = input_tokens + output_tokens
```

Cache creation and cache read are shown as separate counters but are not added to `total_tokens` in this feature.

## UI Changes

## Admin dashboard

Add provider-specific cache ratios to the usage card and rail summary.

### Minimum UI change

Preserve current metrics:

- total tokens
- today tokens
- requests
- cache read tokens
- overall cache hit ratio

Add a compact provider split display, for example:

- `Claude 24% · Codex 6%`

Suggested placements:

- beneath the existing overall cache hit ratio in the usage card
- beneath or alongside the rail cache hit summary

### UI labels

Use user-facing labels:

- `Claude` for provider `anthropic`
- `Codex` for provider `codex`

### Empty state behavior

If a provider has no usage rows:

- show `0%`
- show `0` cache read tokens where needed
- avoid hiding the provider entirely, so the layout remains stable

## Storage Behavior

## DETS schema handling

Because historical compatibility is out of scope, the app should use a clean provider-aware schema for DETS rows.

Acceptable implementation options:

1. Change DETS filenames, for example:
   - `usage_total_v2.dets`
   - `usage_daily_v2.dets`
2. Or clear/recreate DETS contents when opening detects an incompatible key format

Option 1 is preferred because it is simpler and avoids runtime ambiguity.

### Preferred approach

Use new filenames for the provider-aware schema.

Benefits:

- no mixed old/new key formats in one file
- no migration code
- no accidental reads of incomplete historical rows
- easy rollback if needed

## File-Level Impact

Expected primary changes:

- `lib/auth2api_ex/usage_stats.ex`
- `lib/auth2api_ex/accounts/manager.ex`
- `lib/auth2api_ex/handlers/openai.ex`
- `lib/auth2api_ex/handlers/anthropic.ex`
- `lib/auth2api_ex/admin/handler.ex`
- `lib/auth2api_ex/admin/html.ex`
- `test/auth2api_ex/usage_stats_test.exs`
- `test/auth2api_ex/admin/handler_test.exs`

Potentially additional tests near handlers if needed.

## Detailed Requirements

### R1. Provider must be persisted for every new usage row
Every successful recorded request that writes usage stats must include a provider string.

### R2. Totals aggregation must separate providers
Rows with the same email and model but different provider must not merge.

### R3. Daily aggregation must separate providers
Rows with the same date, email, and model but different provider must not merge.

### R4. Admin summary must expose provider breakdown
`/admin/api/usage` must return provider-level summary metrics for at least `anthropic` and `codex`.

### R5. Overall summary must remain available
Existing `summary.cache_hit_ratio` and `summary.cache_read_tokens` must still be returned.

### R6. Totals and daily rows must include provider
Each row returned by the admin usage API must include a `provider` field.

### R7. Historical DETS compatibility is not required
The implementation must not attempt to read, infer, or migrate old provider-less usage rows.

### R8. UI must show provider-specific cache ratios
Admin UI must display Claude and Codex cache ratios derived from the new summary structure.

## Testing Plan

## Unit tests

### UsageStats
Add tests for:

1. recording provider-aware rows
2. same email/model under different providers produce separate rows
3. daily rows include provider
4. restored provider-aware rows load from DETS
5. new DETS filenames or schema paths do not reuse old provider-less storage

### Admin handler
Add tests for:

1. `/admin/api/usage` includes `summary.provider_breakdown`
2. provider breakdown values are computed correctly
3. `totals` rows include `provider`
4. `daily` rows include `provider`

## Integration / handler-level tests

If lightweight to add, verify:

1. Anthropic success path records provider `anthropic`
2. Codex success path records provider `codex`

This may be covered indirectly if `Manager.record_success` calls are updated consistently and admin/API tests validate end-to-end output.

## Rollout Notes

- This is safe to ship as an admin observability enhancement
- Historical usage numbers will reset or diverge depending on chosen DETS filename strategy
- If release notes are maintained, mention that usage stats storage schema changed and previous usage history is not preserved

## Open Questions

1. Should the UI show provider-specific cache read token counts in addition to ratios in v1, or just ratios?
   - Recommendation: ratios only in the main card, keep v1 compact.
2. Should provider breakdown include `today_tokens` too?
   - Recommendation: not necessary for v1.
3. Should we add a provider filter to `/admin/api/usage`?
   - Recommendation: no, not needed for this feature.

## Recommended V1 Scope

Ship exactly this:

- provider-aware usage persistence
- provider-aware admin usage API
- overall + Claude + Codex cache ratios in UI
- no historical compatibility
- no extra filters or charts

This gives most of the value with minimal surface area.
