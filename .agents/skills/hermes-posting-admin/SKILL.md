---
name: hermes-posting-admin
description: Use when the user asks Hermes to change, inspect, test, or operate Discord posting settings, cron posts, webhook triggers, Zenn routes, watcher thresholds, or tech digest delivery.
license: MIT
metadata:
  hermes:
    tags: [posting, discord, cron, webhook, zenn, watcher, operations]
    related_skills: [webhook-subscriptions]
---

# Hermes Posting Admin

## Overview

This skill manages Hermes' Discord posting setup for the `grok-signal-agent`
workspace. Use the repository config as the source of truth, then sync it into
the running Hermes runtime.

The main helper is:

```bash
~/.hermes/bin/hermes-posting-admin.sh
```

It knows how to locate the repo, validate posting config, install runtime
watcher files, register Hermes cron/webhook entries, restart the gateway, and
dry-run watcher triggers.

## When to Use

Use this skill when the user asks in Japanese or English to:

- 投稿設定を変える, 投稿の設定を追加する, Discord投稿を調整する
- cron投稿, morning brief, weekly review, daily review を変更する
- webhook trigger, event trigger, Zenn, X tech digest, X buzz posts を設定する
- 閾値, source route, watcher, 発火条件, cooldown を調整する
- 今の投稿設定を確認する, 発火テストする, 運用開始する

Do not use this for writing a one-off message. Use it only for persistent
posting configuration or trigger operations.

## Source Of Truth

Edit these repo files first:

- `config/hermes-cronjobs.json`: time-based posting jobs.
- `config/hermes-webhooks.json`: event-triggered Hermes routes.
- `config/signal-watchers.json`: feed/page watchers such as Zenn and official AI/developer sources.
- `prompts/tech-digest.md`: long-form X tech digest prompt.
- `prompts/x-buzz-digest.md`: twice-daily X buzz roundup prompt (`hermes-x-buzz-digest-cron.sh`, 06:45/18:40).
- `prompts/curiosity-candidate.md` and `prompts/curiosity-research.md`: bounded daily question selection and source-backed public research note (`hermes-curiosity-cron.sh`, 20:45 to `#hermes-lab`).
- `prompts/hermes-post-style.md`: shared Discord voice for Hermes-chan posts.
- `scripts/*-cron.sh`: no-agent script handlers used by cron/webhooks.

The curiosity job publishes conclusions and evidence, never private memory or
raw chain-of-thought. Keep its one-topic daily budget, direct-URL requirement,
append-only event log, and prohibition on self-modifying code, prompts,
schedules, permissions, or memory write-back.

Runtime files under `~/.hermes/runtime/grok-signal-agent/` are generated copies.
Do not edit runtime copies as the source of truth.

## Standard Workflow

1. Inspect current state:

   ```bash
   ~/.hermes/bin/hermes-posting-admin.sh status
   ```

2. Make the smallest config edit needed in the repo source files.

3. Validate and review routes:

   ```bash
   ~/.hermes/bin/hermes-posting-admin.sh check
   ```

4. Sync the repo config into Hermes runtime:

   ```bash
   ~/.hermes/bin/hermes-posting-admin.sh sync
   ```

5. Test relevant routes:

   ```bash
   ~/.hermes/bin/hermes-posting-admin.sh test-webhooks signal-catchup ai-latest-trigger x-buzz-trigger
   ~/.hermes/bin/hermes-posting-admin.sh dry-run-watchers
   ```

6. Report exactly what changed, what was synced, and which tests passed.

## Quick Operations

Change a watcher source route:

```bash
~/.hermes/bin/hermes-posting-admin.sh set-source-route zenn-trending signal-catchup
~/.hermes/bin/hermes-posting-admin.sh sync
```

Change a watcher threshold:

```bash
~/.hermes/bin/hermes-posting-admin.sh set-source-threshold zenn-trending 74
~/.hermes/bin/hermes-posting-admin.sh sync
~/.hermes/bin/hermes-posting-admin.sh dry-run-watchers
```

Test only lightweight webhook routes:

```bash
~/.hermes/bin/hermes-posting-admin.sh test-webhooks signal-catchup ai-latest-trigger x-buzz-trigger
```

Test expensive routes only when the user clearly asks, because these can create
real Discord posts and may use X search or LLM calls:

```bash
~/.hermes/bin/hermes-posting-admin.sh test-webhooks tech-digest-trigger nightly-dreaming-trigger
```

## Current Posting Model

- `朝6時ブリーフィング｜予定・主要ニュース・Tech/AI` stays as Hermes cron at weekday 06:00 and posts to `#briefings`; its first lines summarize today's schedule and leading general/Tech/AI topics.
- `weekly-review` stays as Hermes cron at Friday 17:00 and posts to `#hermes-alerts`.
- `Hermes health check` stays as Hermes cron at daily 06:30 and posts to `#hermes-alerts` only when attention is needed.
- `tech-digest 18:00` stays as the only scheduled tech digest, on weekdays.
- `tech-digest 08:00`, `tech-digest 12:30`, `daily-review`, and nightly dreaming remain disabled cleanup cron entries.
- `tech-digest-trigger` is a manual/script route for running the full digest outside the cron schedule.
- `ai-latest-trigger` is event-driven and receives high-signal official AI source signals.
- `X buzz digest 06:45` and `X buzz digest 18:40` are Hermes cron jobs (`hermes-x-buzz-digest-cron.sh`) that call `x_search` twice daily and post a short trending-X roundup directly to `#tech-radar`. This replaced the earlier always-on `x-pulse-watcher` LaunchAgent (30-minute polling via the `x-buzz-trigger` webhook), which is retired; `x-buzz-trigger` itself is still registered for manual `test-webhooks` use but nothing sends it automatically anymore.
- `zenn-dev-trigger` and `wbsb-trigger` are disabled cleanup webhook entries. Zenn signals route through `signal-catchup`; wbsb.dev is no longer monitored.
- `signal-catchup` is generic event-driven catch-up.
- `nightly-dreaming-trigger` is memory maintenance, not a normal news post, and routes to `#hermes-alerts`; direct conversation stays in `#hermes-chat`.

## Safety Rules

- Do not delete or reset user state files unless explicitly asked.
- Do not edit `~/.hermes/webhook_subscriptions.json` directly; use sync.
- Do not edit `~/.hermes/cron/jobs.json` directly; use sync or `hermes cron`.
- Do not expose webhook secrets in replies.
- For new Discord channels, require the channel ID before changing delivery.
- For Zenn changes, keep direct source URLs mandatory in prompts.
- Preserve the Hermes-chan posting voice. User-visible Discord posts should not
  become anonymous reports; keep `prompts/hermes-post-style.md` synced.
- If a route is expensive, say so before running a test unless the user asked
  to test all posting routes.

## Verification Checklist

- [ ] `hermes-posting-admin.sh check` passes.
- [ ] `hermes-posting-admin.sh sync` completes.
- [ ] `hermes webhook list` shows the intended routes.
- [ ] `hermes cron list` shows the intended cron jobs.
- [ ] Relevant `test-webhooks` calls return 202 accepted.
- [ ] Relevant watcher dry-runs show expected route names.
