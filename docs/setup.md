# Cloud VM Setup Guide

The current primary setup path is Mac-local. Use
[Mac Local Setup](mac-local.md) first unless you specifically need a remote
server.

This guide builds a private Grok-powered assistant on an Ubuntu VM. The assistant runs Hermes Agent, uses xAI Grok OAuth instead of an xAI API key, searches X through Hermes X Search, and responds through Discord.

## 1. Create the VM

Create an Oracle Cloud Always Free compute instance.

Recommended:

- Image: Ubuntu 24.04 LTS
- Shape: `VM.Standard.A1.Flex` if available
- Fallback: `VM.Standard.E2.1.Micro`
- SSH: key authentication
- Ingress: SSH only at first

Oracle currently documents Always Free compute as including up to two AMD Micro instances, and Ampere A1 resources equivalent to 4 OCPUs and 24 GB memory per month allocation. Availability depends on region and capacity.

## 2. Initial VM Setup

SSH into the VM:

```bash
ssh ubuntu@YOUR_SERVER_IP
```

Update packages and install the minimum host dependencies:

```bash
sudo apt update
sudo apt upgrade -y
sudo apt install -y curl git
```

Hermes' installer can install its own Python and Node runtime dependencies, so avoid adding extra system packages until you need them.

If you want to use the templates in this repository on the VM, clone your repo after you create it on GitHub:

```bash
git clone YOUR_GITHUB_REPO_URL grok-signal-agent
cd grok-signal-agent
```

The remaining commands can be run from any directory unless they reference files in this repo.

## 3. Install Hermes Agent

Install as the normal `ubuntu` user, not with `sudo`:

```bash
curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash
source ~/.bashrc
hermes doctor
```

Expected default layout:

- Code: `~/.hermes/hermes-agent/`
- Command: `~/.local/bin/hermes`
- Data: `~/.hermes/`

Do not commit anything from `~/.hermes/` to this repository.

## 4. Log In to xAI Grok OAuth

On your local PC, open a separate terminal and forward Hermes' loopback OAuth port:

```bash
ssh -N -L 56121:127.0.0.1:56121 ubuntu@YOUR_SERVER_IP
```

On the VM:

```bash
hermes auth add xai-oauth --no-browser
```

Open the printed authorization URL in your local browser, sign in to the xAI account that has SuperGrok, and approve the login.

Then set the model:

```bash
hermes config set model.provider xai-oauth
hermes config set model.default grok-4.3
```

Verify:

```bash
hermes doctor
```

Hermes stores credentials in `~/.hermes/auth.json`. Treat that file as a secret.

## 5. Enable X Search

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

X Search is off by default. Hermes hides the tool from the model unless a valid xAI credential is available.

## 6. Create the Discord Bot

In Discord:

1. Open <https://discord.com/developers/applications>.
2. Create a new application and bot.
3. Enable **Server Members Intent** and **Message Content Intent** on the Bot page.
4. Save the bot token somewhere private, not in this repo.
5. Invite the bot to a private Discord server with `bot` and `applications.commands` scopes.
6. Enable Discord Developer Mode, then copy your numeric Discord User ID.

Keep the first version in a private server. Do not add public or shared servers until allowlists are confirmed.

## 7. Configure Discord Gateway

On the VM:

```bash
hermes gateway setup
```

Choose Discord, enter the bot token, and allow only your numeric Discord user ID.

If you use environment variables, copy [examples/.env.example](../examples/.env.example) to a private file outside the repo, for example:

```bash
mkdir -p ~/.hermes
cp examples/.env.example ~/.hermes/.env
chmod 600 ~/.hermes/.env
```

Then edit `~/.hermes/.env` on the VM and replace placeholders. Do not commit that file.

## 8. Test the Gateway

Start the gateway in the foreground:

```bash
hermes gateway
```

In a Discord DM or private server channel where the bot is present:

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

## 9. Run Gateway Permanently

Preferred on a VPS/headless host:

```bash
sudo hermes gateway install --system
sudo hermes gateway start --system
sudo hermes gateway status --system
journalctl -u hermes-gateway -f
```

Hermes also supports a user service:

```bash
hermes gateway install
hermes gateway start
hermes gateway status
journalctl --user -u hermes-gateway -f
```

Use only one of system service or user service unless you intentionally run multiple Hermes installations.

If you need a manually managed unit instead, adapt [systemd/hermes-gateway.service](../systemd/hermes-gateway.service) and install it:

```bash
sudo cp systemd/hermes-gateway.service /etc/systemd/system/hermes-gateway.service
sudo systemctl daemon-reload
sudo systemctl enable --now hermes-gateway
sudo systemctl status hermes-gateway
journalctl -u hermes-gateway -f
```

## 10. Daily X Summary Prompt

Use [prompts/x-daily-summary.md](../prompts/x-daily-summary.md) as the base instruction for a manual Discord request first.

After the DM flow is stable, automate it with Hermes cron or another scheduler and deliver the result to the home channel set by `/sethome`.

## Troubleshooting

### OAuth callback fails

Keep this SSH tunnel open on your local PC during login:

```bash
ssh -N -L 56121:127.0.0.1:56121 ubuntu@YOUR_SERVER_IP
```

Then rerun:

```bash
hermes auth add xai-oauth --no-browser
```

### X Search is not used

Run:

```bash
hermes tools
hermes doctor
```

Confirm `X (Twitter) Search` is enabled and `xai-oauth` credentials are valid.

### Discord replies to unexpected users

Stop the gateway and inspect your Discord configuration and environment:

```bash
hermes gateway stop || true
grep -R "DISCORD_ALLOWED_USERS" ~/.hermes
```

Only your numeric user ID should be allowed.

### Discord bot is online but does not answer

Confirm **Message Content Intent** is enabled in the Discord Developer Portal,
then restart the gateway.

### Service starts but bot does not answer

Check logs:

```bash
journalctl -u hermes-gateway -f
```

Also confirm the service runs as the same user that completed Hermes login, usually `ubuntu`, because OAuth credentials live under that user's `~/.hermes/`.

## Next Steps

1. Add a daily X summary automation.
2. Add Slack only after deciding which workspace/channel scopes are acceptable.
3. Keep Discord allowlists tight before adding shared servers.
4. Enable image, video, TTS, or transcription tools through `hermes tools` after the core assistant is reliable.
