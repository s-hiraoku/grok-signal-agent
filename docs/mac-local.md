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
signal-driven tech posts are triggered by webhook subscriptions, while
morning/review posts remain intentional wall-clock jobs.
Older repo-managed Gateway and heartbeat LaunchAgents are removed by the
installer.

The signal watcher LaunchAgent runs from
`~/.hermes/runtime/grok-signal-agent/`, where the installer copies the watcher
script and `config/signal-watchers.json`. Re-run the installer after changing
watcher code or source thresholds.

The X pulse watcher uses the same runtime directory and runs every 30 minutes
through `com.shiraoku.grok-signal-agent.x-pulse-watcher`. It samples recent
`x_search` results and triggers `tech-digest-trigger` only when enough new
direct X/Twitter URLs appear.

By default, event-triggered posts route to:

- `tech-digest-trigger` and `signal-catchup` post to `#tech-digest`.
- `nightly-dreaming-trigger` posts to `#ask-hermes`.

The active cron posts route to:

- `平日9:50リマインダー` posts to `#morning-brief`.
- `金曜17時gbrainサマリー` posts gbrain/honcho status to `#weekly-review`.
- `毎晩23:30 gbrain/honcho daily review` posts to `#daily-review`.

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
launchctl print gui/$(id -u)/com.shiraoku.grok-signal-agent.x-pulse-watcher
```

The Gateway service starts immediately. Cron jobs wait for their next scheduled
time; webhook jobs wait for the next matching signed POST.

The installer also installs エルメスちゃん's self-growth loop:

- Each digest is saved under `~/.hermes/state/digests/`.
- Each digest quality report is saved under
  `~/.hermes/state/digest-quality/`.
- Each digest metadata file is saved under
  `~/.hermes/state/digest-metadata/`.
- Each digest is evaluated under `~/.hermes/state/evaluations/`.
- Explicit Discord feedback/follow-up captures are saved under
  `~/.hermes/state/user-feedback/`.
- A nightly dreaming job saves recomposition reports under
  `~/.hermes/state/dreaming/` and refreshes
  `~/.hermes/state/hermes-chan-memory.md` as the current working memory view.
- A weekly reflection job updates `~/.hermes/state/hermes-chan-memory.md` on
  Sunday at 21:10 local time.
- Hermes cron script timeout is set to 300 seconds so the tech digest script can
  finish X curation plus self-evaluation without being marked as failed.

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

The installer also registers and approves Gateway hooks for memory and
feedback:

```yaml
hooks:
  pre_gateway_dispatch:
    - command: ~/.hermes/bin/hermes-gbrain-remember.sh
      timeout: 30
    - command: ~/.hermes/bin/hermes-discord-feedback.sh
      timeout: 30
```

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
`/webhooks/signal-catchup` and posts to the `tech-digest` Discord channel when
an external service POSTs a signed event. This is for event-driven sources such
as GitHub, release monitors, uptime alerts, RSS-to-webhook bridges, or custom
watchers. X/news services that do not provide push events still need an
upstream watcher; Hermes should receive the watcher's event, not poll on a cron.
The former tech digest time slots are replaced by `/webhooks/tech-digest-trigger`.
Morning brief and gbrain/honcho review posts are registered as Hermes cron jobs
because they are intentionally time-based.

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
