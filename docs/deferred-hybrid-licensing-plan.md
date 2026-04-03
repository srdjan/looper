# Deferred Hybrid Licensing Plan

Status: Deferred / not implemented

## Goal

Preserve the agreed design for an open-core Looper with a paid team tier unlocked by an org-scoped license key, without changing the current plugin behavior.

This document is archival. The current plugin remains free, local-first, and does not implement any licensing, billing, activation, or team sync behavior described below.

## Product Decisions

- Keep one official public plugin: `looper@claude-plugins-official`.
- Keep the current free solo workflow intact and high quality.
- Do not gate core loop quality, stack detection, or bundled `quality-gates`.
- Add a paid team tier inside the same plugin, unlocked with an org-scoped license key.
- Define the v1 paid feature boundary on the collaboration axis:
  - shared team context
  - shared team coaching
  - org-wide consistency via synced team rules
- Do not include shared memory, multi-repo context, or private marketplace distribution in v1.
- Keep `looper` as the plugin name; Timok is branding, not the install namespace.

## Plugin-Side Design

The plugin remains shell-first. Do not add a TypeScript runtime to Looper for licensing.

Planned plugin-side additions:

- new shell-based licensing helpers under `kernel/`
- a new bundled package named `team-rules`
- new commands:
  - `/looper:activate`
  - `/looper:license-status`
  - `/looper:deactivate`

Planned runtime behavior:

- resolve cached license state on `SessionStart`
- verify signed license and team rules locally
- attempt best-effort refresh only on `SessionStart`
- never perform license network calls in `PreToolUse`, `PostToolUse`, or `Stop`
- fall back silently to free mode on any licensing failure

Feature-gating rules:

- `team-rules` is loaded only when a valid cached license includes the `team_rules` feature
- free mode continues to work normally when the license is missing, expired, revoked, invalid, unreadable, or network refresh fails
- licensing helpers must never break the hook pipeline

## Service-Side Design

Billing, key issuance, and signed rules delivery live in a separate service, not in this repository.

Planned responsibilities:

- Stripe checkout
- 14-day org trial
- org creation and org-scoped key issuance
- signed license envelope generation
- signed team rules bundle delivery
- admin editing of shared team rules

Planned endpoint surface:

- `POST /v1/licenses/activate`
- `POST /v1/licenses/refresh`
- `GET /v1/licenses/status`

Planned licensing model:

- one org key, not per-seat keys
- signed JSON envelopes verified locally by the plugin
- only `trialing` and `active` count as licensed inside the plugin

## Command and Cache Surface

Planned plugin commands:

- `/looper:activate`
  - accept an org license key
  - call the license service
  - write cache only after a valid signed response
  - fetch and cache the team rules bundle
- `/looper:license-status`
  - show free vs licensed mode
  - show org, status, features, and cache freshness
- `/looper:deactivate`
  - remove the local cached license and team rules
  - return the plugin to free mode

Planned local cache files:

- `${XDG_CONFIG_HOME:-$HOME/.config}/looper/license.json`
- `${XDG_CONFIG_HOME:-$HOME/.config}/looper/team-rules.json`

Planned kernel env surface:

- `LOOPER_LICENSE_MODE`
- `LOOPER_LICENSE_ORG_ID`
- `LOOPER_LICENSE_FEATURES`
- `LOOPER_TEAM_RULES`

## Team Rules Constraints

V1 team rules are intentionally limited to additive, non-executable guidance.

Allowed team rules fields:

- `context[]`
- `coaching.on_failure`
- `coaching.on_budget_low`
- `coaching.urgency_at`

Precedence rules:

- local project config remains authoritative for executable behavior
- local gate commands and checks are never replaced by team rules in v1
- local project coaching overrides team coaching when both are present
- team rules add context and optional coaching only

## Testing Checklist

Future implementation should verify:

- valid signed cache enables `team-rules`
- invalid signature falls back to free mode
- expired cache falls back to free mode
- refresh failure with an unexpired cache keeps team mode active until expiry
- activation writes cache only after a valid response
- deactivation removes both cache files
- team rules inject shared context and coaching only
- local project coaching overrides team coaching
- team rules never modify gates or checks
- free install works with no activation flow
- multiple developers can activate the same org key successfully

## Explicit Deferrals

These are intentionally out of scope for the first implementation:

- shared memory across sessions
- multi-repo or org-wide codebase context
- private marketplace distribution
- admin editing from inside the plugin
- TypeScript-based gate loaders or runtime licensing modules inside the plugin
- any paid gating of core solo quality

## Implementation Notes for Future Work

When this work is resumed:

- keep the free tier excellent and complete for solo users
- gate scope, not output quality
- keep licensing local-first with signed cache verification
- treat all network interactions as optional refresh paths, not critical-path runtime dependencies
- prefer quiet upgrade nudges over blocking errors
