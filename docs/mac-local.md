# Mac Local Setup

This guide runs the Hermes Discord gateway directly on your Mac with a per-user
`launchd` service. It avoids a public server, public inbound ports, and Oracle
Cloud capacity issues.

## Fit

Use this mode when:

- You are fine with the assistant running only while this Mac is awake and online.
- You want the fastest path to a private Discord assistant.
- You do not need a public webhook endpoint.

The Discord gateway can run from a normal home network because it uses outbound
connections. Do not expose local ports to the internet.

## 1. Install Hermes

Install the command as your normal macOS user:

```bash
curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash
export PATH="$HOME/.local/bin:$PATH"
hermes doctor
```

Expected local paths:

- Command: `~/.local/bin/hermes`
- Data and credentials: `~/.hermes/`
- OAuth credentials: `~/.hermes/auth.json`

Never commit anything under `~/.hermes/`.

## 2. Log In to xAI Grok OAuth

Because Hermes is running on the same Mac as your browser, no SSH tunnel is
needed:

```bash
hermes auth add xai-oauth
```

Verify the login:

```bash
hermes doctor
```

Set the default provider and model:

```bash
hermes config set model.provider xai-oauth
hermes config set model.default grok-4.3
```

Optional quick check:

```bash
hermes -z "日本語で一言だけ返事して: Hermes local OK" --provider xai-oauth --model grok-4.3
```

## 3. Enable X Search

Run:

```bash
hermes tools
```

Enable:

```text
X (Twitter) Search
```

Choose:

```text
xAI Grok OAuth (SuperGrok Subscription)
```

## 4. Create the Discord Bot

In Discord:

1. Open <https://discord.com/developers/applications>.
2. Click **New Application**.
3. Open **Bot** and create or reset the bot token.
4. Enable **Server Members Intent**.
5. Enable **Message Content Intent**.
6. Save the bot token somewhere private.
7. Invite the bot to a private server with `bot` and `applications.commands`
   scopes.
8. In Discord, enable **User Settings → Advanced → Developer Mode**.
9. Right-click your own user profile and choose **Copy User ID**.

Keep the first version in a private server or DM-only. Configure only your
numeric Discord user ID as allowed.

## 5. Configure and Test the Gateway

Configure Discord:

```bash
hermes gateway setup
```

Select **Discord** when prompted. Paste the bot token and your numeric Discord
user ID. Do not paste the bot token into this repository or chat.

Start the gateway in the foreground first:

```bash
hermes gateway
```

In a Discord DM or private server channel where the bot is present, test:

```text
こんにちは。短く自己紹介して。
```

Then test X Search:

```text
今日のAIエージェント関連のXの重要投稿を調べて、日本語で要約して
```

If that works, set the current DM or channel as the home channel:

```text
/sethome
```

Stop the foreground gateway with `Ctrl-C` before installing the `launchd`
service.

## 6. Install the LaunchAgent

From this repository:

```bash
chmod +x scripts/install-macos-launchagent.sh scripts/uninstall-macos-launchagent.sh
./scripts/install-macos-launchagent.sh
```

The script installs or refreshes Hermes' built-in Gateway LaunchAgent:

```text
~/Library/LaunchAgents/ai.hermes.gateway.plist
```

It also syncs the explicit Hermes cron jobs and removes disabled legacy jobs
when they are present. Hermes Gateway stays responsible for process runtime;
signal-driven tech posts are triggered by webhook subscriptions, while full X
tech digest, morning, and weekly review posts remain intentional wall-clock jobs.
Older repo-managed Gateway and heartbeat LaunchAgents are removed by the
installer.

The signal watcher LaunchAgent runs from
`~/.hermes/runtime/grok-signal-agent/`, where the installer copies the watcher
script and `config/signal-watchers.json`. The watcher can track feed/page
items and standalone document URLs such as PDFs; document sources are keyed by
content hash so a replacement at the same URL can trigger a catch-up post after
the first-run prime. Re-run the installer after changing watcher code or source
thresholds.

X/Twitter buzz used to be handled by an always-on `x-pulse-watcher`
LaunchAgent polling `x_search` every 30 minutes and posting through the
`x-buzz-trigger` webhook. That was retired in favor of
`hermes-x-buzz-digest-cron.sh`, a Hermes cron job that runs twice daily
(08:45 and 18:40) and posts a short trending-X roundup directly to
`#tech-signals`, matching the fixed-schedule pattern of the other digest
jobs instead of continuous polling. The full X tech digest is posted by cron
on weekdays at 18:00.

By default, event-triggered posts route to:

- `tech-digest-trigger` posts to `#tech-digest`.
- `ai-latest-trigger` posts to `#ai-latest`.
- `signal-catchup` posts to `#tech-signals`.
- `nightly-dreaming-trigger` posts to `#hermes-chat`.

`x-buzz-trigger` remains registered for manual `hermes-posting-admin.sh
test-webhooks` use, but nothing sends it automatically now that the X buzz
digest posts directly through cron.

The legacy `zenn-dev-trigger` and `wbsb-trigger` subscriptions are disabled by
default. Zenn watcher signals now route through `signal-catchup` so
source-specific article notifications do not create extra channel noise.
wbsb.dev is no longer monitored.

The active cron posts route to:

- `tech-digest 18:00` posts to `#tech-digest` on weekdays.
- `平日8:00リマインダー` posts to `#morning-brief`, including today's Google
  Workspace Calendar events. Monday posts also include the current week's
  schedule.
- `Hermes health check` posts to `#hermes-info` only when attention is needed.
- `金曜17時gbrainサマリー` posts gbrain/honcho status to `#weekly-review`.
- `X buzz digest 08:45` and `X buzz digest 18:40` post trending X/Twitter
  roundups to `#tech-signals` daily.

Webhook subscription definitions live in `config/hermes-webhooks.json`; the
registration script reads that file and creates or updates Hermes webhook
subscriptions. Time-based post definitions live in `config/hermes-cronjobs.json`.
See `docs/scheduled-jobs.md` for the extension model.

Validate and inspect jobs:

```bash
scripts/register-hermes-cronjobs.sh
scripts/register-hermes-webhooks.sh
hermes cron list
hermes webhook list
launchctl print gui/$(id -u)/ai.hermes.gateway
launchctl print gui/$(id -u)/com.shiraoku.grok-signal-agent.signal-watcher
```

Before running the registration scripts or installer, copy
`config/hermes-channels.example.json` to `config/hermes-channels.local.json`
and replace the placeholders with your Discord channel IDs. The local file is
ignored by git. Registration rejects placeholder targets so personal Discord
IDs are not committed accidentally.

The Gateway service starts immediately. Cron jobs wait for their next scheduled
time; webhook jobs wait for the next matching signed POST.

The installer also installs ヘルメスちゃん's self-growth loop:

- Each digest is saved under `~/.hermes/state/digests/`.
- Each digest quality report is saved under
  `~/.hermes/state/digest-quality/`.
- Each digest metadata file is saved under
  `~/.hermes/state/digest-metadata/`.
- Each digest is evaluated by the delayed `tech-digest evaluation 18:20` job
  under `~/.hermes/state/evaluations/`.
- Explicit Discord feedback/follow-up captures are saved under
  `~/.hermes/state/user-feedback/`.
- A nightly dreaming job saves recomposition reports under
  `~/.hermes/state/dreaming/` and refreshes
  `~/.hermes/state/hermes-chan-memory.md` as the current working memory view.
- A weekly reflection job updates `~/.hermes/state/hermes-chan-memory.md` on
  Sunday at 21:10 local time.
- Hermes cron script timeout is set to 300 seconds so the tech digest script can
  finish X curation and delivery. Self-evaluation and optional gbrain write-back
  run in the delayed evaluation job so they do not block the Discord post.

Details are in [self-growth.md](self-growth.md).

Optional Obsidian vault access:

```bash
# Read/write within this vault only. Requires Node.js/npm for npx.
OBSIDIAN_VAULT_PATH="$HOME/Documents/Notes" \
  scripts/hermes-obsidian-mcp-setup.sh --restart-gateway

# Safer read-only mode:
scripts/hermes-obsidian-mcp-setup.sh --vault "$HOME/Documents/Notes" --read-only
```

After the restart, ask Hermes from Discord or the CLI to search/read/update a
specific note in the Obsidian vault. Details are in [obsidian.md](obsidian.md).

Optional Google Calendar access:

```bash
# Requires Google Calendar API and Google Calendar MCP API enabled in Google Cloud.
# Store GOOGLE_CALENDAR_MCP_CLIENT_ID and GOOGLE_CALENDAR_MCP_CLIENT_SECRET in ~/.hermes/.env.
scripts/hermes-google-calendar-mcp-setup.sh --login --restart-gateway
```

After the restart, ask Hermes from Discord: `今日の予定は？`. The default setup is
read-only and exposes only calendar listing, event lookup, and availability
tools. Details are in [google-calendar.md](google-calendar.md).

The installer also registers and approves Gateway hooks for memory and
feedback:

```yaml
hooks:
  pre_gateway_dispatch:
    - command: ~/.hermes/bin/hermes-gbrain-remember.sh
      timeout: 30
    - command: ~/.hermes/bin/hermes-mnemo-memory-hook.sh
      timeout: 30
    - command: ~/.hermes/bin/hermes-discord-feedback.sh
      timeout: 30
```

`hermes-mnemo-memory-hook.sh` only records messages from channel IDs listed in
`HERMES_MNEMO_MEMORY_CHANNEL_IDS`; ordinary chat channels are ignored.

If you add hooks manually, approve them once:

```bash
hermes gateway run --replace --accept-hooks
hermes hooks doctor
hermes gateway restart
```

Optional event-driven catch-up via webhook:

```yaml
# ~/.hermes/config.yaml
platforms:
  webhook:
    enabled: true
    extra:
      host: "127.0.0.1"
      port: 8644
      secret: "<global-secret>"
```

```bash
scripts/register-hermes-webhooks.sh
hermes webhook list
hermes gateway restart
```

The default `signal-catchup` subscription listens at
`/webhooks/signal-catchup` and posts to the `tech-signals` Discord channel when
an external service POSTs a signed event. This is for event-driven sources such
as GitHub, release monitors, uptime alerts, RSS-to-webhook bridges, or custom
watchers. Zenn feed signals use the same consolidated route. The full X tech
digest, X buzz digest, morning brief, and weekly gbrain/honcho review posts
are registered as Hermes cron jobs because they are intentionally
time-based rather than push-driven; `x_search` has no push/webhook mode of
its own, so both digests poll it on a fixed schedule instead of waiting for
an event. `/webhooks/x-buzz-trigger` remains registered for manual testing
but is no longer driven by an always-on watcher.

## 7. Operate the Service

Check status:

```bash
launchctl print gui/$(id -u)/ai.hermes.gateway
```

Follow logs:

```bash
tail -f ~/.hermes/logs/gateway.log ~/.hermes/logs/gateway.error.log
```

Restart:

```bash
hermes gateway restart
```

Stop and remove the LaunchAgent:

```bash
./scripts/uninstall-macos-launchagent.sh
```

## 8. Keep the Mac Available

For stable operation:

- Keep the Mac awake while you expect replies.
- Keep network access available.
- Avoid logging out of the macOS user session that owns the LaunchAgent.

For temporary testing, you can keep the machine awake with:

```bash
caffeinate -dimsu
```

Use macOS Battery or Lock Screen settings for a longer-lived setup.

## Security Rules

- Keep the Discord bot in a private server until the allowlist is proven.
- Allow only your numeric Discord user ID.
- Do not commit `~/.hermes/auth.json`.
- Do not commit `~/.hermes/.env`.
- Do not commit `~/.hermes/state/`.
- Do not commit Discord bot tokens.
- If a token leaks, reset it in the Discord Developer Portal and run
  `hermes gateway setup` again.
