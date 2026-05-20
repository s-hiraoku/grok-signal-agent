# grok-signal-agent

A minimal Hermes Agent setup for a personal Grok-powered assistant that monitors X signals and responds via Discord.

This repository is configuration and documentation only. It is intended to be safe to publish: keep OAuth tokens, Discord bot tokens, real user IDs, and runtime Hermes state outside the repo.

## Target Setup

- macOS local always-on user session, using `launchd`
- Hermes Agent
- xAI Grok OAuth with an active SuperGrok subscription
- Hermes X Search tool
- Discord gateway

Cloud VM deployment is still possible later, but the current primary path is a
Mac-local service so there is no dependency on Oracle Cloud capacity.

The first milestone is a private Discord bot that can answer:

```text
今日のAIエージェント関連のXの重要投稿を調べて、日本語で要約して
```

## Repository Layout

```text
README.md
docs/setup.md
systemd/hermes-gateway.service
launchd/com.shiraoku.grok-signal-agent.hermes-gateway.plist
scripts/install-macos-launchagent.sh
scripts/uninstall-macos-launchagent.sh
prompts/x-daily-summary.md
examples/.env.example
```

## Quick Start

### Mac Local

1. Install Hermes Agent on the Mac:

```bash
curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash
export PATH="$HOME/.local/bin:$PATH"
hermes doctor
```

2. Log in to xAI Grok OAuth:

```bash
hermes auth add xai-oauth
hermes config set model.provider xai-oauth
hermes config set model.default grok-4.3
```

This uses `xAI Grok OAuth (SuperGrok Subscription)`.

3. Enable X Search:

```bash
hermes tools
```

Turn on `X (Twitter) Search` and choose `xAI Grok OAuth (SuperGrok Subscription)`.

4. Create a Discord application and bot in the Discord Developer Portal, invite it to a private server, then configure and test the gateway:

```bash
hermes gateway setup
hermes gateway
```

5. In a Discord DM or private server channel where the bot is present, run:

```text
/sethome
```

6. Install the macOS LaunchAgent:

```bash
chmod +x scripts/install-macos-launchagent.sh scripts/uninstall-macos-launchagent.sh
./scripts/install-macos-launchagent.sh
```

Full Mac-local details are in [docs/mac-local.md](docs/mac-local.md).
The older cloud VM notes are in [docs/setup.md](docs/setup.md).

## Running as a Service

On macOS, use the LaunchAgent template in this repository:

```bash
launchctl print gui/$(id -u)/com.shiraoku.grok-signal-agent.hermes-gateway
tail -f ~/.hermes/logs/hermes-gateway.out.log ~/.hermes/logs/hermes-gateway.err.log
```

On a Linux VM, prefer Hermes' built-in service installer:

```bash
sudo hermes gateway install --system
sudo hermes gateway start --system
sudo hermes gateway status --system
journalctl -u hermes-gateway -f
```

The file [systemd/hermes-gateway.service](systemd/hermes-gateway.service) is a conservative fallback template if you want to manage the unit yourself.

## Security Rules

- Allow only your Discord numeric user ID.
- Do not commit `~/.hermes/auth.json`.
- Do not commit `~/.hermes/.env`.
- Do not commit Discord, xAI, or any other messaging credentials.
- Use SSH key authentication if you later move the setup to a VM.
- Keep the Discord bot in a private server first; add public or shared servers later only after allowlists are confirmed.

## References

- [xAI: Connect Grok to Hermes Agent](https://x.ai/news/grok-hermes)
- [Hermes: xAI Grok OAuth](https://hermes-agent.nousresearch.com/docs/guides/xai-grok-oauth)
- [Hermes: X Search](https://hermes-agent.nousresearch.com/docs/user-guide/features/x-search)
- [Hermes: Discord](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/discord/)
- [Hermes: Messaging Gateway](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/)
- [Oracle Cloud Always Free Resources](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm)
