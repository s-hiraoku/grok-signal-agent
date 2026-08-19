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
config/hermes-webhooks.json
launchd/com.shiraoku.grok-signal-agent.weekly-self-reflection.plist
scripts/install-macos-launchagent.sh
scripts/uninstall-macos-launchagent.sh
scripts/register-hermes-cronjobs.sh
scripts/register-hermes-webhooks.sh
scripts/hermes-morning-brief-cron.sh
scripts/hermes-tech-digest-cron.sh
scripts/hermes-dreaming-cron.sh
scripts/hermes-review-cron.sh
scripts/hermes-daily-review-cron.sh
scripts/hermes-weekly-review-cron.sh
scripts/hermes-x-buzz-digest-cron.sh
scripts/hermes-weekly-self-reflection.sh
scripts/hermes-gbrain-backfill.sh
scripts/hermes-gbrain-retrieval.sh
scripts/hermes-gbrain-remember.sh
scripts/hermes-discord-feedback.sh
scripts/hermes-digest-lint.sh
scripts/hermes-alert.sh
scripts/hermes-health-check-cron.sh
scripts/hermes-obsidian-mcp-setup.sh
scripts/hermes-jina-mcp-setup.sh
scripts/hermes-google-calendar-mcp-setup.sh
prompts/x-daily-summary.md
prompts/tech-digest.md
prompts/x-buzz-digest.md
prompts/hermes-chan-identity.md
prompts/evaluate-digest.md
prompts/nightly-dreaming.md
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

6. Configure local Discord channel IDs, then install the macOS LaunchAgent:

```bash
cp config/hermes-channels.example.json config/hermes-channels.local.json
$EDITOR config/hermes-channels.local.json
chmod +x scripts/install-macos-launchagent.sh scripts/uninstall-macos-launchagent.sh
./scripts/install-macos-launchagent.sh
```

Full Mac-local details are in [docs/mac-local.md](docs/mac-local.md).
The self-growth loop for ヘルメスちゃん is in
[docs/self-growth.md](docs/self-growth.md).
The optional Obsidian vault connection is in
[docs/obsidian.md](docs/obsidian.md).
The optional Jina Reader connection is in
[docs/jina-reader.md](docs/jina-reader.md).
The optional Google Calendar connection is in
[docs/google-calendar.md](docs/google-calendar.md).
The Zenn source note is in
[docs/zenn-dev.md](docs/zenn-dev.md).
The triggered job architecture is in
[docs/scheduled-jobs.md](docs/scheduled-jobs.md).
The older cloud VM notes are in [docs/setup.md](docs/setup.md).

## Discord Jobs

Discord jobs use two mechanisms:

- Event-triggered webhooks for high-signal, source-backed alerts.
- Hermes cron for intentionally time-based operational posts.

```bash
scripts/register-hermes-cronjobs.sh    # syncs morning/review cron jobs and removes disabled legacy jobs
scripts/register-hermes-webhooks.sh    # creates/updates webhook triggers
hermes cron list
hermes webhook list
```

The webhook registration script reads
[config/hermes-webhooks.json](config/hermes-webhooks.json) and creates trigger
routes:

- `tech-digest-trigger` to `#briefings`
- `ai-latest-trigger` to `#ai-official`
- `x-buzz-trigger` to `#tech-radar`
- `github-pr-review-trigger` to `#tech-radar`
- `signal-catchup` to `#tech-radar`
- `nightly-dreaming-trigger` to `#hermes-alerts`

The legacy source-specific route for Zenn remains as a disabled cleanup entry.
Zenn watcher signals now flow through `signal-catchup` so low-signal article
notifications do not scatter across multiple channels. wbsb.dev is no longer monitored.

Channel IDs must be configured locally before registration. The committed
defaults are placeholders so personal Discord targets stay out of the
repository. Copy
[config/hermes-channels.example.json](config/hermes-channels.example.json) to
`config/hermes-channels.local.json`, replace the channel IDs, and rerun the
registration or installer script. The local override file is ignored by git.

The active cron jobs are:

- `朝6時ブリーフィング｜予定・主要ニュース・Tech/AI` to `#briefings`, using direct RSS/Atom feeds
  plus Google Workspace Calendar events
- `tech-digest 18:00` to `#briefings` on weekdays only
- `tech-digest evaluation 18:20` to `#hermes-alerts`, normally silent while it
  evaluates the latest digest and updates memory/gbrain artifacts
- `Hermes health check` to `#hermes-alerts`, posting only when attention is needed
- independent `Hermes runtime health watchdog` checks every 5 minutes and sends
  failures directly to `#hermes-alerts`, even when Gateway is down; unchanged
  failures are limited to one reminder per hour and recovery is also reported
- `Hermes disk watchdog` to `#hermes-alerts`, posting only when disk usage crosses
  the configured threshold
- `Hermes SSL expiry watchdog` to `#hermes-alerts`, posting only when configured
  certificates approach expiry
- `金曜17時gbrainサマリー` to `#hermes-alerts`, using gbrain/honcho status

The older `discord-heartbeat` LaunchAgent is treated as legacy and removed by
the macOS installer. It is replaced by the narrower runtime health watchdog,
which checks the existing health report and bypasses Gateway for alert delivery.

### Channel Design

Hermes channel routing is organized by what readers expect to find in each
channel, not by whether the post was started by cron or a webhook.

| Channel | Purpose |
| --- | --- |
| `#hermes-chat` | Direct conversation with Hermes. |
| `#hermes-alerts` | Health checks, failures, gateway notices, watchdogs, internal evaluations, and the weekly gbrain/honcho summary. |
| `#ai-official` | High-signal official AI/model/agent/tooling updates. |
| `#tech-radar` | Sparse X buzz, Zenn/dev article, GitHub PR, and generic technical signals that pass stricter watcher gates. |
| `#briefings` | Scheduled reading: weekday morning brief and weekday evening tech digest. |

The current default config keeps `#ai-official` and `#tech-radar` as separate
Discord channels. Keep official AI/model/tooling updates in `#ai-official`;
route broader technical signals and X buzz to `#tech-radar`.

Keep `#briefings` focused on deliberate summaries and `#hermes-chat` focused
on conversation. Automatic notifications
should be quiet by default: source watchers only post when a signal clears the
stricter thresholds, and lower-signal source movement should remain in logs and
runtime state rather than becoming Discord noise.

External movement must come from an upstream event source such as GitHub,
release monitors, uptime alerts, RSS-to-webhook bridges, or a custom watcher.
Hermes receives those signed webhook POSTs and posts the result to Discord. The
intended split is:

- Hermes built-in service: keep Hermes Gateway running.
- Signal watcher: monitor Zenn, Anthropic, GitHub Changelog, OpenAI
  News, Cloudflare Changelog, Hacker News, Publickey, release feeds,
  standalone PDFs, and other sources; score/dedupe/cooldown changes with high
  thresholds before any Discord post is triggered.
- AI latest artifacts: for `ai-latest-trigger`, the signal watcher also writes
  local run artifacts under `~/.hermes/state/ai-latest/`, including
  `signals.json`, `analysis.md`, and `summary.html`. New-feature signals are
  split into one fact-checked HTML/CSS feature card per feature
  (`infographic-01.html` plus `infographic-01.png`,
  `infographic-02.html` plus `infographic-02.png`, ...), with the first image
  also copied to `infographic.png` for previews. The PNGs are rendered from
  the HTML with Playwright when `summary_png_renderer` is `playwright`.
  Discord posts attach all generated feature card images. `facts.json` and `factcheck.md`
  record the official-source evidence used before rendering. Version-only
  release notes stay in HTML/Markdown without a separate summary image. The
  route is split by provider, so OpenAI and Anthropic produce separate payloads
  and latest directories such as
  `~/.hermes/public/ai-latest/latest/openai/` and
  `~/.hermes/public/ai-latest/latest/anthropic/`. Every run is archived under
  `~/.hermes/archive/ai-latest/`.
  Anthropic and OpenAI changelog-style pages are watched as snapshots, so
  Markdown/HTML diffs can be preserved even when a source has no RSS feed.
- GitHub PR event source: send review-request, CI, workflow, or stale-review
  payloads to `github-pr-review-trigger` so Hermes summarizes action items only
  when there is a concrete PR signal.
- Hermes webhook platform: event ingress and delivery targets.
- Handler scripts: job implementation details such as tech digest generation,
  deferred digest evaluation, digest quality linting/metadata, alerts, and
  gbrain write-back, plus gbrain/honcho daily and weekly reviews.
- Gateway hooks: Discord message/event-triggered actions.
- Job prompts and channel targets: versioned in this repository, registered
  into Hermes runtime state by scripts.

See [docs/scheduled-jobs.md](docs/scheduled-jobs.md) before adding new
trigger-driven behavior.

The watcher configuration is in
[config/signal-watchers.json](config/signal-watchers.json). It currently
monitors Zenn, Anthropic News/Engineering/Research, Google AI, Mistral, Meta
AI, Hugging Face, LangChain, GitHub Changelog, OpenAI News,
Cloudflare Changelog, Hacker News best, Publickey, and Hermes Agent
releases, plus the OpenAI Codex maxxing whitepaper PDF as a standalone document
source. For `document` sources, the watcher stores a content hash so a later
PDF replacement at the same URL can still become a new signal. First run primes
state only so old articles/documents are not posted in bulk; later runs post
only threshold-crossing new signals. Snapshot format revisions also prime a new
baseline silently, which prevents a switch from HTML to Markdown from looking
like a product update. Global cooldown bypass is disabled and provider scoring
is balanced to keep one vendor from crowding out the others. AI official
sources route to `#ai-official`;
broader developer and article sources route to `#tech-radar`. The macOS
installer copies the watcher runtime to
`~/.hermes/runtime/grok-signal-agent/`; re-run the installer after changing the
watcher code or config.

X/Twitter buzz is posted by `X buzz digest 06:45` and `X buzz digest 18:40`,
twice-daily Hermes cron jobs (`scripts/hermes-x-buzz-digest-cron.sh`,
[prompts/x-buzz-digest.md](prompts/x-buzz-digest.md)) that call `x_search`
once per run and post a short trending-topic roundup straight to
`#tech-radar`. This replaced an earlier always-on `x-pulse-watcher`
LaunchAgent that polled `x_search` every 30 minutes through the
`x-buzz-trigger` webhook; continuous polling burned xAI/Grok usage faster
than a fixed twice-daily schedule needs. See "X Buzz Digest" in
[docs/scheduled-jobs.md](docs/scheduled-jobs.md) for its preflight and
streak-alert behavior.

The scheduled tech digest uses bounded collection timeouts. When `x_search`
cannot provide direct post links, it falls back to a balanced set of official
AI vendor pages; if no source-backed digest can be built, it exits cleanly and
posts nothing rather than emitting tool errors or an incomplete digest.

## Digest Quality And Feedback

The 18:00 `tech-digest` run writes the user-facing digest and quality artifacts
under `~/.hermes/state/`. The 18:20 `tech-digest evaluation` job then evaluates
the latest digest and performs optional gbrain write-back outside the delivery
timeout path.

- `digests/<ts>.md`: the delivered briefing.
- `digest-metadata/<ts>.json`: section titles, inferred categories, source
  URLs, accounts, duplicate counts, and lint status.
- `digest-quality/<ts>.md`: human-readable lint errors and warnings.
- `evaluations/<ts>.md`: delayed self-evaluation of the delivered digest.
- `dreaming/<ts>.md`: nightly memory recomposition report; raw inputs are kept,
  while the current working memory view is regenerated.

The linter checks that each detailed section has a direct X/Twitter source URL,
that section counts stay in the expected 3-12 range, that search-result URLs do
not leak into references, and that recent source duplicates/topic imbalance are
visible as warnings. Lint failures log and alert by default but do not block
Discord delivery unless `HERMES_DIGEST_LINT_STRICT=1` is set.

Operational alerts always append to `~/.hermes/logs/hermes-alerts.log` and, by
default, use `hermes send` to deliver directly to `discord:hermes-alerts` without
requiring a running Gateway. To change delivery, set one of:

```bash
HERMES_ALERT_DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/...
HERMES_ALERT_COMMAND='your-command-that-reads-stdin'
HERMES_ALERT_TARGET=discord:another-channel
```

The signal watcher and the X buzz digest cron job call the same alert helper
when webhook delivery fails, required webhook secrets are missing, or
`x_search` cannot run for several runs in a row. The `Hermes health check`
cron job also reports gateway, cron, webhook, watcher, and xAI/Grok access
issues to `#hermes-alerts`; normal runs stay silent.

Explicit Discord feedback and follow-up requests can be captured with the
Gateway hook `~/.hermes/bin/hermes-discord-feedback.sh`. Supported message
prefixes include:

```text
評価: 今日のセキュリティ項目は良かった
/feedback too much AI hype today
追跡: このMCP脆弱性の続報を見て
/track browser API rollout next week
深掘り: gbrain integration patterns
```

Captured items are saved under `~/.hermes/state/user-feedback/` and, when
gbrain is available, upserted as `feedback` or `followup` pages. Digest
retrieval surfaces `note`, `feedback`, and `followup` pages as high-priority
guidance.

## Running as a Service

On macOS, use Hermes' built-in LaunchAgent. The repository installer registers
webhook triggers, removes older posting cron jobs and repo-managed Gateway
agents, and restarts this service:

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

## Obsidian Vault Access (Optional)

ヘルメスちゃん can access an Obsidian vault through Hermes' MCP support and
the official filesystem MCP server. Access is limited to the vault directory
you pass to the setup script.

```bash
OBSIDIAN_VAULT_PATH="$HOME/Documents/Notes" \
  scripts/hermes-obsidian-mcp-setup.sh --restart-gateway
```

Use `--read-only` if you want search/list/read access without note writes or
edits. Full setup, verification, and safety notes are in
[docs/obsidian.md](docs/obsidian.md).

## Jina Reader Access (Optional)

Hermes can use Jina Reader through the official remote MCP server to convert
public URLs into clean Markdown. Anonymous URL reading works without an API key,
subject to Jina's rate limits:

```bash
scripts/hermes-jina-mcp-setup.sh --restart-gateway
```

For higher limits, set `JINA_API_KEY` in `~/.hermes/.env` and rerun with
`--api-key-env JINA_API_KEY`. Details are in
[docs/jina-reader.md](docs/jina-reader.md).

## Google Calendar Access (Optional)

Hermes can use Google's official remote Calendar MCP server to answer schedule
questions from Discord, such as `今日の予定は？`. The repository helper registers
the Calendar MCP server as read-only by default.

```bash
scripts/hermes-google-calendar-mcp-setup.sh --login --restart-gateway
```

Set `GOOGLE_CALENDAR_MCP_CLIENT_ID` and
`GOOGLE_CALENDAR_MCP_CLIENT_SECRET` in `~/.hermes/.env` before login. Details
are in [docs/google-calendar.md](docs/google-calendar.md).

## Tests

Run the shell regression tests:

```bash
tests/run.sh
```

## Mnemo-like Memory Layer (Optional)

ヘルメスちゃん can keep an on-demand, mnemo-inspired local memory without
requiring `覚えて:` / `/remember` prefixes. The Gateway hook
`scripts/hermes-mnemo-memory-hook.sh` captures only messages posted in
explicitly configured memory channels, stores them in a local SQLite database,
exports Markdown copies, and lets you search them later.

This is **off until a memory channel is configured**. Normal conversation is
not captured.

```bash
# Install the helper and Gateway hook.
./scripts/install-macos-launchagent.sh

# Configure the Discord channel IDs that should behave as memory inboxes.
export HERMES_MNEMO_MEMORY_CHANNEL_IDS="123456789012345678"

# Ask from the shell, or wire the command into a Hermes tool/prompt flow later.
~/.hermes/bin/hermes-mnemo-memory.py recall "朝の通知"
~/.hermes/bin/hermes-mnemo-memory.py backlinks codex
~/.hermes/bin/hermes-mnemo-memory.py red-links
~/.hermes/bin/hermes-mnemo-memory.py graph --format mermaid
~/.hermes/bin/hermes-mnemo-memory.py curator status
```

Captured data lives under:

- `~/.hermes/mnemo/mnemo.sqlite`: primary local store.
- `~/.hermes/mnemo/knowledge/memory/*.md`: exported memory notes.
- `~/.hermes/mnemo/knowledge/knowledge/*.md`: exported source-style notes.

Short messages become `memory`. Messages with the mnemo-style sections
`Source:`, `Why captured:`, and `Connections:` become `knowledge`. `[[slug]]`
links are indexed for backlinks, red-link detection, graph output, and curator
status. Recall increments `view_count` and records a `session` audit row.

## gbrain Memory Backend (Optional)

ヘルメスちゃん's self-growth loop can use [`garrytan/gbrain`](https://github.com/garrytan/gbrain)
as a searchable memory backend: it stores each digest and self-evaluation as a
page, lets digest triggers recall what was recently covered, and runs an
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

Set these in the Hermes Gateway environment before triggered jobs run. The
repository helper scripts prepend `~/.bun/bin` to `PATH` before invoking
`gbrain`.

| Flag | Job | Effect |
| --- | --- | --- |
| `HERMES_GBRAIN_RETRIEVAL=1` | digest trigger | Inject recent digest headlines + the latest evaluation's improvement notes into the prompt as soft guidance. |
| `HERMES_GBRAIN_WRITEBACK=1` | digest trigger | Upsert each digest and evaluation into the brain (`digest-<ts>` / `evaluation-<ts>`). |
| `HERMES_GBRAIN_RECONCILE=1` | weekly | Upsert a `learnings-<ts>` page, export the brain to `~/.hermes/brain/pages`, `git commit` it, then run `gbrain dream`. |
| `GBRAIN_SEARCH_MODE=query` | digest trigger | Switch retrieval from keyword search to hybrid (vector) search. Requires an embedding provider key configured in the brain (default is keyword `search`). |

### Legacy remember-prefix hook (optional)

You can tell ヘルメスちゃん to remember something straight from Discord. A
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
captured. Prefer the mnemo-like memory-channel flow above when you do not want
to type a remember prefix.

The macOS installer registers and approves the memory/feedback hooks. To do it
manually:

```bash
# 1. config.yaml — register the hooks (paths must be absolute):
#    hooks:
#      pre_gateway_dispatch:
#        - command: ~/.hermes/bin/hermes-gbrain-remember.sh
#          timeout: 30
#        - command: ~/.hermes/bin/hermes-mnemo-memory-hook.sh
#          timeout: 30
#        - command: ~/.hermes/bin/hermes-discord-feedback.sh
#          timeout: 30
# 2. Approve the hooks once (Hermes gates new shell hooks):
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
# After digest triggers run, inspect Hermes webhook and gateway logs:
hermes webhook list

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
