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
config/hermes-cronjobs.json
launchd/com.shiraoku.grok-signal-agent.weekly-self-reflection.plist
scripts/install-macos-launchagent.sh
scripts/uninstall-macos-launchagent.sh
scripts/register-hermes-cronjobs.sh
scripts/hermes-tech-digest-cron.sh
scripts/hermes-weekly-self-reflection.sh
scripts/hermes-gbrain-backfill.sh
scripts/hermes-gbrain-retrieval.sh
scripts/hermes-gbrain-remember.sh
prompts/x-daily-summary.md
prompts/tech-digest.md
prompts/hermes-chan-identity.md
prompts/evaluate-digest.md
prompts/weekly-self-reflection.md
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
The self-growth loop for エルメスちゃん is in
[docs/self-growth.md](docs/self-growth.md).
The scheduled job architecture is in
[docs/scheduled-jobs.md](docs/scheduled-jobs.md).
The older cloud VM notes are in [docs/setup.md](docs/setup.md).

## Discord Scheduled Posts

Scheduled Discord posts are managed by Hermes cron. There is one scheduler and
one place to inspect jobs:

```bash
hermes cron list
launchctl print gui/$(id -u)/ai.hermes.gateway
scripts/register-hermes-cronjobs.sh
```

The registration script reads [config/hermes-cronjobs.json](config/hermes-cronjobs.json)
and creates recurring jobs if they are missing:

- `tech-digest 08:00`, `tech-digest 12:30`, `tech-digest 18:00` to
  `#tech-digest`
- `平日9:50リマインダー` to `#morning-brief`
- `金曜17時gbrainサマリー` to `#weekly-review`

The older `discord-heartbeat` LaunchAgent is treated as legacy and removed by
the macOS installer.

Event-driven Discord triggers should be added through Hermes Gateway hooks, not
through another scheduler. The intended split is:

- Hermes built-in service: keep Hermes Gateway running.
- Hermes cron: time-based jobs and delivery targets.
- Cron scripts: job implementation details such as tech digest generation,
  digest/evaluation persistence, and gbrain write-back.
- Gateway hooks: Discord message/event-triggered actions.
- Job prompts and channel targets: versioned in this repository, registered
  into Hermes runtime state by scripts.

See [docs/scheduled-jobs.md](docs/scheduled-jobs.md) before adding new scheduled
or trigger-driven behavior.

## Running as a Service

On macOS, use Hermes' built-in LaunchAgent. The repository installer registers
cron jobs, removes older repo-managed Gateway agents, and restarts this service:

```bash
launchctl print gui/$(id -u)/ai.hermes.gateway
tail -f ~/.hermes/logs/gateway.log ~/.hermes/logs/gateway.error.log
```

On a Linux VM, prefer Hermes' built-in service installer:

```bash
sudo hermes gateway install --system
sudo hermes gateway start --system
sudo hermes gateway status --system
journalctl -u hermes-gateway -f
```

The file [systemd/hermes-gateway.service](systemd/hermes-gateway.service) is a conservative fallback template if you want to manage the unit yourself.

## Tests

Run the shell regression tests:

```bash
tests/run.sh
```

## gbrain Memory Backend (Optional)

エルメスちゃん's self-growth loop can use [`garrytan/gbrain`](https://github.com/garrytan/gbrain)
as a searchable memory backend: it stores each digest and self-evaluation as a
page, lets digest cron jobs recall what was recently covered, and runs an
enrichment cycle during the weekly reflection. The full design and storage
model are in [docs/self-growth.md](docs/self-growth.md).

This is **off by default**. With none of the flags below set, the digest and
weekly jobs behave exactly as without gbrain. Each phase is enabled
independently and is defensive — a missing brain or a failed gbrain call is
logged and ignored, so curation and Discord delivery are never blocked.

### Setup

```bash
# 1. Install gbrain (TypeScript / Bun) and create a local PGLite brain.
bun install -g github:garrytan/gbrain

# 2. Backfill existing self-growth state into the brain.
#    Inits the brain on first run with --no-embedding (no API key needed).
./scripts/hermes-gbrain-backfill.sh
gbrain list -n 20            # verify pages imported

# 3. Reinstall the LaunchAgents so the helper script and flags take effect.
./scripts/install-macos-launchagent.sh
```

### Feature flags

Set these in the Hermes Gateway environment before scheduled jobs run, and make
sure `~/.bun/bin` is on the agent `PATH` so the `gbrain` binary resolves.

| Flag | Job | Effect |
| --- | --- | --- |
| `HERMES_GBRAIN_RETRIEVAL=1` | digest cron | Inject recent digest headlines + the latest evaluation's improvement notes into the prompt as soft guidance. |
| `HERMES_GBRAIN_WRITEBACK=1` | digest cron | Upsert each digest and evaluation into the brain (`digest-<ts>` / `evaluation-<ts>`). |
| `HERMES_GBRAIN_RECONCILE=1` | weekly | Upsert a `learnings-<ts>` page, export the brain to `~/.hermes/brain/pages`, `git commit` it, then run `gbrain dream`. |
| `GBRAIN_SEARCH_MODE=query` | digest cron | Switch retrieval from keyword search to hybrid (vector) search. Requires an embedding provider key configured in the brain (default is keyword `search`). |

### Remember things from Discord (optional)

You can tell エルメスちゃん to remember something straight from Discord. A
`pre_gateway_dispatch` shell hook (`scripts/hermes-gbrain-remember.sh`) watches
incoming messages and, when one starts with a remember-prefix, saves the rest
as a `note` page in the brain. Digest retrieval then surfaces recent
notes first, as instructions to follow:

```text
覚えて: 今後はセキュリティ系の話題を毎回1つ入れて
/remember security incidents should always be flagged
```

Recognized prefixes: `覚えて` / `おぼえて` / `記憶して` / `/remember` /
`remember` (followed by an optional `:` or `：`). Normal conversation is never
captured.

Enable it:

```bash
# 1. config.yaml — register the hook (path must be absolute):
#    hooks:
#      pre_gateway_dispatch:
#        - command: ~/.hermes/bin/hermes-gbrain-remember.sh
#          timeout: 30
# 2. Approve the hook once (Hermes gates new shell hooks):
hermes gateway run --replace --accept-hooks   # Ctrl-C after it starts
hermes hooks doctor                           # should now show ✓
# 3. Restart the background gateway:
hermes gateway restart
```

### Hybrid search (optional)

Keyword search works with no API key. To enable vector/hybrid search:

```bash
export OPENAI_API_KEY=sk-…   # or VOYAGE_API_KEY / ZEROENTROPY_API_KEY
( cd ~/.hermes/brain && gbrain config set embedding_model openai:text-embedding-3-large )
( cd ~/.hermes/brain && gbrain embed --all )
# then add GBRAIN_SEARCH_MODE=query to the Gateway environment
```

### Check it is working

```bash
# After digest cron jobs run, inspect Hermes cron and gateway logs:
hermes cron list

# Pages accumulating in the brain:
gbrain list -n 30
```

## Security Rules

- Allow only your Discord numeric user ID.
- Do not commit `~/.hermes/auth.json`.
- Do not commit `~/.hermes/.env`.
- Do not commit runtime self-memory or digest logs from `~/.hermes/state/`.
- Do not commit Discord, xAI, or any other messaging credentials.
- Use SSH key authentication if you later move the setup to a VM.
- Keep the Discord bot in a private server first; add public or shared servers later only after allowlists are confirmed.

## Roadmap

Planned next steps, roughly in priority order:

- **Hybrid (vector) search.** The gbrain integration currently runs on keyword
  search (`gbrain search`, no API key). Next is to configure an embedding
  provider, run `gbrain embed --all`, and flip digest retrieval to
  `GBRAIN_SEARCH_MODE=query` so retrieval ranks prior digests/evaluations by
  semantic similarity instead of literal terms. See the "Hybrid search" steps
  above and [docs/self-growth.md](docs/self-growth.md).
- **Grow the knowledge graph.** Digests are currently isolated pages, so
  `gbrain dream`'s back-link and consolidate steps are no-ops (every page is an
  orphan). Add `[[wikilinks]]` / typed edges between related topics and
  accounts so enrichment, dedup, and "what do we keep over-covering" analysis
  start to pay off.
- **Tune retrieval guidance.** Iterate on how much recalled context is injected
  (counts, recency window, per-category balance) once there is enough live data
  to judge whether it improves digest quality.
- **Promote learnings into stable preferences.** Let the weekly reflection
  consolidate recurring `learnings-<ts>` pages into a durable preferences page
  in the brain, rather than only rewriting the flat memory file.
- **Optional remote brain.** Keep the local PGLite + stdio MCP setup as the
  default, but document a migration path to Postgres/Supabase + HTTP MCP for
  multi-device or shared-agent use.

## References

- [xAI: Connect Grok to Hermes Agent](https://x.ai/news/grok-hermes)
- [Hermes: xAI Grok OAuth](https://hermes-agent.nousresearch.com/docs/guides/xai-grok-oauth)
- [Hermes: X Search](https://hermes-agent.nousresearch.com/docs/user-guide/features/x-search)
- [Hermes: Discord](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/discord/)
- [Hermes: Messaging Gateway](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/)
- [Oracle Cloud Always Free Resources](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm)
