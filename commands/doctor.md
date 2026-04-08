---
description: Inspect repo truth and compare it to the current Looper config
allowed-tools: Bash(bash:*), Bash(jq:*), Bash(cat:*), Bash(test:*), Read
---

# Looper Doctor

Inspect the current repository, synthesize the config Looper would bootstrap
today, and compare that proposal with the current `.claude/looper.json`.

## Steps

1. Run:

```bash
bash "$(claude plugin root looper)/packages/quality-gates/lib/doctor-report.sh"
```

2. Print the output directly if the script succeeds.

3. If the script is unavailable, say:

```
Looper doctor is unavailable in this install. Run /looper:looper-config for guided repair.
```
