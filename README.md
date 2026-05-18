# grok-signal-agent

A minimal Hermes Agent setup for a personal Grok-powered assistant that monitors X signals and responds via Telegram.

This repository is configuration and documentation only. It is intended to be safe to publish: keep OAuth tokens, Telegram bot tokens, real user IDs, and runtime Hermes state outside the repo.

## Target Setup

- Oracle Cloud Always Free VM
- Ubuntu 24.04 LTS
- Hermes Agent
- xAI Grok OAuth with an active SuperGrok subscription
- Hermes X Search tool
- Telegram DM gateway

The first milestone is a private Telegram DM bot that can answer:

```text
今日のAIエージェント関連のXの重要投稿を調べて、日本語で要約して
```

## Repository Layout

```text
README.md
docs/setup.md
systemd/hermes-gateway.service
prompts/x-daily-summary.md
examples/.env.example
```

## Quick Start

1. Create an Oracle Cloud Always Free Ubuntu VM.
2. SSH into the VM as a non-root user, usually `ubuntu`.
3. Install Hermes Agent:

```bash
sudo apt update
sudo apt upgrade -y
sudo apt install -y curl git
curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash
source ~/.bashrc
```

4. Log in to xAI Grok OAuth from the VM:

```bash
# On your local PC, in a separate terminal:
ssh -N -L 56121:127.0.0.1:56121 ubuntu@YOUR_SERVER_IP

# On the VM:
hermes auth add xai-oauth --no-browser
hermes model
```

Choose `xAI Grok OAuth (SuperGrok Subscription)`.

5. Enable X Search:

```bash
hermes tools
```

Turn on `X (Twitter) Search` and choose `xAI Grok OAuth (SuperGrok Subscription)`.

6. Create a Telegram bot with `@BotFather`, get your numeric Telegram user ID from `@userinfobot`, then configure the gateway:

```bash
hermes gateway setup
hermes gateway
```

7. In the Telegram DM with your bot, run:

```text
/sethome
```

Full details are in [docs/setup.md](docs/setup.md).

## Running as a Service

Prefer Hermes' built-in service installer on the VM:

```bash
sudo hermes gateway install --system
sudo hermes gateway start --system
sudo hermes gateway status --system
journalctl -u hermes-gateway -f
```

The file [systemd/hermes-gateway.service](systemd/hermes-gateway.service) is a conservative fallback template if you want to manage the unit yourself.

## Security Rules

- Allow only your Telegram numeric user ID.
- Do not commit `~/.hermes/auth.json`.
- Do not commit `~/.hermes/.env`.
- Do not commit Telegram, Slack, Discord, or xAI credentials.
- Use SSH key authentication.
- Keep Telegram DM as the first integration; add group chats later only after allowlists are confirmed.

## References

- [xAI: Connect Grok to Hermes Agent](https://x.ai/news/grok-hermes)
- [Hermes: xAI Grok OAuth](https://hermes-agent.nousresearch.com/docs/guides/xai-grok-oauth)
- [Hermes: X Search](https://hermes-agent.nousresearch.com/docs/user-guide/features/x-search)
- [Hermes: Telegram](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/telegram/)
- [Hermes: Messaging Gateway](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/)
- [Oracle Cloud Always Free Resources](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm)
