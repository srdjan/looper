# Publishing Looper to Anthropic's Marketplace

This runbook is for publishing `looper` to Anthropic's official Claude Code plugin marketplace.

## Naming Decision First

Anthropic's official marketplace does not expose plugins as `/timok.looper`.

The current official install model is:

```bash
claude plugin install <plugin-name>@claude-plugins-official
```

That means the valid official forms are:

- `looper@claude-plugins-official`
- `timok-looper@claude-plugins-official` if the plugin is renamed

Slash commands follow the plugin name:

- `/looper:bootstrap`
- `/looper:looper-config`

If you want a true `timok` namespace such as `looper@timok`, that requires a separate self-hosted marketplace named `timok`. It is not the naming model for Anthropic's official directory.

## Recommended Path

Use one of these two options:

1. Keep the current plugin name `looper`.
2. Rename the plugin to `timok-looper` before submission if Timok must appear in the plugin ID.

Unless there is a strong branding requirement, keep `looper` and use `Timok` in the author/publisher branding.

## Current Repo State

This repo is already in good shape for submission:

- plugin manifest exists at `.claude-plugin/plugin.json`
- hooks are wired through `hooks/hooks.json`
- docs describe plugin-based install and usage
- package metadata matches the plugin version
- validation passes with `claude plugin validate .`
- tests pass with `npm test`

## Preflight Checklist

Run these commands from the repo root:

```bash
claude plugin validate .
npm test
claude plugin --help
```

Then do a local plugin smoke test:

```bash
claude --plugin-dir /Users/srdjans/Code/looper
```

Inside Claude Code, verify:

- `/looper:bootstrap` exists
- `/looper:looper-config` exists
- the plugin starts cleanly in a project
- first-run `.claude/looper.json` bootstrap still works

## Step 1: Confirm Public Identity

Check `.claude-plugin/plugin.json` and confirm:

- `name`
- `version`
- `description`
- `author`
- `homepage`
- `repository`
- `license`
- `keywords`

Current repo expectation:

- plugin name: `looper`
- official marketplace install target after approval: `looper@claude-plugins-official`

If you need the Timok brand in the install ID, change:

```json
{
  "name": "timok-looper"
}
```

Then update any docs and command examples that refer to `/looper:*`, since slash-command prefixes will follow the new plugin name.

## Step 2: Validate the Manifest

Run:

```bash
claude plugin validate .
```

Expected result:

- validation passes with no schema errors

If validation fails, fix the manifest before doing anything else.

## Step 3: Run the Full Test Suite

Run:

```bash
npm test
```

Expected result:

- the hook/kernel/package tests all pass

Do not submit with known test failures unless they are clearly unrelated and documented.

## Step 4: Do a Clean Local Install Test

Run the plugin from the repo directly:

```bash
claude --plugin-dir /Users/srdjans/Code/looper
```

Use a small scratch project if needed and verify:

- session start hook fires once
- no duplicate hook registration
- `.claude/looper.json` auto-generates when absent
- stop-hook behavior still loops correctly

If anything is flaky locally, fix it before submission.

## Step 5: Review Submission Policy and Terms

Open the official submission entry points:

- `https://claude.ai/settings/plugins/submit`
- `https://platform.claude.com/plugins/submit`

Before submitting:

- read the plugin submission requirements
- confirm the repository is public
- confirm the repo root is the plugin root
- make sure the README explains what the plugin does, prerequisites, and local development flow

## Step 6: Submit the Plugin

Preferred submission artifact:

- GitHub repository URL: `https://github.com/srdjan/looper`

Alternative:

- zip archive of the plugin root

When filling out the submission:

- use `looper` as the plugin name unless you explicitly rename it first
- use `Timok` in branding only if you are keeping the `looper` plugin ID
- do not describe the plugin as already listed unless approval has happened

## Step 7: Wait for Anthropic Review

Anthropic runs automated review before listing.

Important constraints:

- approval is not guaranteed
- later updates require re-submission
- official listing name is still tied to the plugin name, not a custom namespace path

## Step 8: Verify the Real Marketplace Install

After approval, test the real marketplace install:

```bash
claude plugin install looper@claude-plugins-official
claude plugin list
```

If renamed:

```bash
claude plugin install timok-looper@claude-plugins-official
claude plugin list
```

Then reload Claude Code and verify the commands again.

## If You Want a Timok Namespace

If the real goal is `looper@timok`, use a self-hosted marketplace instead of Anthropic's official one.

That path looks like:

1. create a marketplace manifest
2. host the plugin catalog yourself
3. add the marketplace in Claude Code
4. install with `claude plugin install looper@timok`

That is a separate distribution track from the official Anthropic directory.

## Release Commands

For the current repo, the release checklist is:

```bash
git pull --ff-only
claude plugin validate .
npm test
git status --short
```

If all checks pass, submit the GitHub repo through Anthropic's official form.

## Final Recommendation

For Anthropic's official marketplace:

- keep `looper` as the plugin name
- brand the publisher as Timok
- install as `looper@claude-plugins-official`

Only rename to `timok-looper` if branding in the install ID matters more than preserving the current command namespace.
