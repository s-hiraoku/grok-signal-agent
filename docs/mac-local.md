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

The script renders
`launchd/com.shiraoku.grok-signal-agent.hermes-gateway.plist` into:

```text
~/Library/LaunchAgents/com.shiraoku.grok-signal-agent.hermes-gateway.plist
```

It also installs the Discord curation heartbeat. The heartbeat posts three
times per day in the local macOS user session:

- 08:00
- 12:30
- 18:00

The gateway and healthcheck services start immediately. The heartbeat waits for
the next scheduled time after installation.

The installer also installs エルメスちゃん's self-growth loop:

- Each digest is saved under `~/.hermes/state/digests/`.
- Each digest is evaluated under `~/.hermes/state/evaluations/`.
- A weekly reflection job updates `~/.hermes/state/hermes-chan-memory.md` on
  Sunday at 21:10 local time.

Details are in [self-growth.md](self-growth.md).

## 7. Operate the Service

Check status:

```bash
launchctl print gui/$(id -u)/com.shiraoku.grok-signal-agent.hermes-gateway
```

Follow logs:

```bash
tail -f ~/.hermes/logs/hermes-gateway.out.log ~/.hermes/logs/hermes-gateway.err.log
```

Restart:

```bash
launchctl kickstart -k gui/$(id -u)/com.shiraoku.grok-signal-agent.hermes-gateway
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
