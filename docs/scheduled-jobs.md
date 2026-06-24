# Scheduled And Triggered Jobs Design

Discord posting work uses both Hermes webhooks and Hermes cron. Webhooks own
signal-driven posts; cron is reserved for intentionally time-based operational
posts such as the X tech digest, weekday morning brief, and daily/weekly
reviews.

Hermes' built-in LaunchAgent is only process supervision. It starts and
restarts Hermes Gateway. It must not contain business schedules, channel
routing, prompt text, or job-specific behavior.

User-visible Discord posts should share the voice rules in
`prompts/hermes-post-style.md`: friendly, recognizably ヘルメスちゃん, but still
accurate and source-linked. Script-backed jobs inject this file at runtime;
prompt-backed cron/webhook jobs carry the same rules directly in their prompt
text.

## Responsibilities

| Layer | Owns | Must not own |
| --- | --- | --- |
| Hermes built-in LaunchAgent | Gateway process lifecycle | schedules, channels, prompts |
| Hermes Gateway | runtime host for webhooks, cron, and hooks | job-specific business logic |
| Hermes webhook platform | event ingress and delivery target | deciding when external events happen |
| `config/hermes-webhooks.json` | trigger declarations: route, channel, mode | shell control flow |
| `scripts/register-hermes-webhooks.sh` | generic JSON-to-Hermes-webhook registration | hardcoded trigger definitions |
| `config/hermes-cronjobs.json` | explicit time-based jobs and disabled legacy cleanup declarations | signal-driven event detection |
| `scripts/register-hermes-cronjobs.sh` | creates/updates enabled cron jobs and removes disabled legacy jobs by name | deciding external event significance |
| job handler scripts | concrete job behavior | scheduling or channel routing |
| Gateway hooks | Discord event-triggered actions | time-based scheduling |

## Current Triggers

`config/hermes-webhooks.json` declares:

- `signal-catchup`
- `tech-digest-trigger`
- `x-buzz-trigger`
- `zenn-dev-trigger`
- `wbsb-trigger`
- `nightly-dreaming-trigger`

The `tech-digest-trigger` route uses `mode: "script"` and calls
`hermes-tech-digest-cron.sh`. This is now a manual/script route for exceptional
full digest runs outside the normal 08:00/12:30/18:00 cron schedule. The script
generates the digest, saves digest/evaluation artifacts, lints the digest,
emits structured metadata, optionally writes back to gbrain, and prints the
final Discord message to stdout. Hermes' webhook CLI currently accepts prompt
subscriptions rather than native script subscriptions, so
`scripts/register-hermes-webhooks.sh` renders a deterministic shell prompt for
script-mode routes. Registration fails if the referenced repository script is
missing, and the rendered command checks that the runtime copy exists before
running it. Run `scripts/install-macos-launchagent.sh` or
`~/.hermes/bin/hermes-posting-admin.sh sync` after changing script-backed
routes.

The `x-buzz-trigger` route uses `mode: "prompt"` and receives X pulse watcher
signals. It does not run the full digest. It posts a short Hermes-chan style
introduction to the engagement-qualified X/Twitter posts in
`payload.qualified_candidates`.

The `nightly-dreaming-trigger` route uses `mode: "script"` and calls
`hermes-dreaming-cron.sh`. That script is an internal memory maintenance
handler: it reads recent conversation excerpts, digests, evaluations, explicit
feedback, built-in Hermes memories, and prior reflections, then writes a full
dreaming report under `~/.hermes/state/dreaming/`. It does not delete raw
memory; it replaces only the current working memory view
`~/.hermes/state/hermes-chan-memory.md` with the recomposed section from the
report.

## Quality Gate

`hermes-tech-digest-cron.sh` runs `hermes-digest-lint.sh` after saving each
digest. The linter writes:

- `~/.hermes/state/digest-metadata/<ts>.json`
- `~/.hermes/state/digest-quality/<ts>.md`

Hard failures include missing direct X/Twitter URLs, per-section source gaps,
wrong section counts, and Google/search-result URLs. Warnings include repeated
recent source URLs and inferred category imbalance. By default, failures are
reported through `hermes-alert.sh` and logged, but the digest still delivers.
Set `HERMES_DIGEST_LINT_STRICT=1` if you prefer failed lint to block delivery.

Alerts are log-only unless an operator configures
`HERMES_ALERT_DISCORD_WEBHOOK_URL` or `HERMES_ALERT_COMMAND`.

The feed/page signal watcher and X pulse watcher also use
`hermes-alert.sh` for operational failures that would otherwise be visible only
in logs: missing webhook secrets, webhook delivery failures, source-wide feed
failures, and `x_search` failures. Set `HERMES_ALERT_SCRIPT` only when you need
to point a watcher at a non-default alert helper during tests or custom
runtime layouts.

## Local Channel Overrides

`config/hermes-cronjobs.json` contains the default channel map used by both
cron and webhook registration. To keep personal Discord channel IDs out of a
reusable checkout, copy `config/hermes-channels.example.json` to
`config/hermes-channels.local.json`, replace only the channels that differ, and
rerun registration:

```bash
cp config/hermes-channels.example.json config/hermes-channels.local.json
$EDITOR config/hermes-channels.local.json
scripts/register-hermes-cronjobs.sh
scripts/register-hermes-webhooks.sh
```

`config/hermes-channels.local.json` is ignored by git. Set
`HERMES_CHANNELS_CONFIG=/path/to/channels.json` when you want to use a
different override file in tests or automation. Any channel missing from the
override falls back to the committed `channels` entry.

## Current Cron Jobs

`config/hermes-cronjobs.json` declares these active time-based posts:

- `平日9:50リマインダー`: weekday 09:50 `#morning-brief`, using
  `hermes-morning-brief-cron.sh` to fetch direct RSS/Atom sources and Google
  Workspace Calendar events before posting. Monday posts include both today's
  schedule and the current week's schedule.
- `tech-digest 08:00`: daily 08:00 `#tech-digest`.
- `tech-digest 12:30`: daily 12:30 `#tech-digest`.
- `tech-digest 18:00`: daily 18:00 `#tech-digest`.
- `金曜17時gbrainサマリー`: Friday 17:00 `#weekly-review`, using
  `hermes-weekly-review-cron.sh` to summarize gbrain and honcho updates/status.
- `毎晩23:30 gbrain/honcho daily review`: nightly 23:30 `#daily-review`, using
  `hermes-daily-review-cron.sh`.

The old nightly dreaming post remains disabled in the same file so
`scripts/register-hermes-cronjobs.sh` can remove stale registered jobs by name.

## Source Links

Scheduled posts must preserve direct reference links so readers can inspect the
source later.

- X/Twitter-derived items must include the direct post URL from `x.com` or
  `twitter.com`.
- Google/Web-derived items must include the original page URL, such as the
  article, official announcement, repository, release note, or documentation
  page. Do not use Google search result or redirect URLs as references.
- Items without a verifiable source URL should be omitted from scheduled news
  and digest posts.

## Adding A Triggered Job

Add a new entry to `config/hermes-webhooks.json`.

Use `mode: "prompt"` when the job can be expressed as a self-contained Hermes
prompt:

```json
{
  "id": "example-trigger",
  "name": "example-trigger",
  "channel": "morning-brief",
  "mode": "prompt",
  "secret_env": "HERMES_POST_TRIGGER_WEBHOOK_SECRET",
  "events": [],
  "skills": [],
  "prompt": "Post a short reminder."
}
```

Use `mode: "script"` when the job needs deterministic file IO, retries,
artifact persistence, external command calls, or custom post-processing:

```json
{
  "id": "example-script-trigger",
  "name": "example-script-trigger",
  "channel": "weekly-review",
  "mode": "script",
  "script": "example-script-cron.sh",
  "secret_env": "HERMES_POST_TRIGGER_WEBHOOK_SECRET",
  "events": [],
  "skills": []
}
```

Scripts must live under `~/.hermes/scripts/` at runtime. The installer copies
repository scripts matching `scripts/*-cron.sh` there, and webhook registration
rejects script-mode entries whose script name does not match that runtime sync
contract.

`hermes-morning-brief-cron.sh` intentionally does its own source collection
instead of relying on a prompt-only search request. It reads direct feeds such
as NHK NEWS WEB, GitHub Changelog, OpenAI News, Cloudflare Changelog,
Publickey, and Zenn, reads Google Workspace Calendar events when
`~/.hermes/google_token.json` is available, then posts the schedule plus
source-linked general and Tech/AI/development items.

Disabled legacy posting cron entries remain in `config/hermes-cronjobs.json`
with `enabled: false`. Running `scripts/register-hermes-cronjobs.sh` removes
matching registered cron jobs by name. Set `HERMES_CRONJOBS_REMOVE_DISABLED=0`
only when you want to inspect old jobs without deleting them.

## Event Triggers

Discord message-triggered behavior should not be added to Hermes cron. Add it
through Hermes Gateway hooks, using the same separation:

- hook registration decides which Discord events are observed;
- a trigger router reads a declarative trigger config;
- handler scripts implement concrete behavior.

That keeps event triggers extensible without adding a second scheduler.

Current event-trigger helpers:

- `hermes-gbrain-remember.sh`: captures explicit "remember this" messages as
  `note` pages.
- `hermes-discord-feedback.sh`: captures explicit feedback and follow-up/deep
  dive requests as `feedback` or `followup` pages, with a local fallback under
  `~/.hermes/state/user-feedback/`.

External service-triggered behavior should use Hermes' webhook platform. The
repository keeps dynamic webhook subscriptions in
`config/hermes-webhooks.json`, while `scripts/register-hermes-webhooks.sh`
registers them with `hermes webhook subscribe`.

`scripts/hermes-signal-watcher.py` is the default upstream watcher. It reads
`config/signal-watchers.json`, fetches configured feeds/pages/documents,
dedupes stable URLs or document content hashes, scores new items with keyword
weights, applies route cooldowns, and sends only threshold-crossing payloads to
Hermes webhooks. Zenn signals route to
`zenn-dev-trigger`, wbsb.dev signals route to `wbsb-trigger`, and generic
technical signals route to `signal-catchup` as `#tech-signals` posts. Generic
sources include Anthropic News/Engineering/Research, GitHub Changelog, OpenAI
News, the OpenAI Codex maxxing whitepaper PDF, Cloudflare Changelog, Hacker
News frontpage/best, Publickey, and release feeds. When enough generic signals
arrive together, the watcher can also route to `tech-digest-trigger`. The macOS
installer runs it through
`com.shiraoku.grok-signal-agent.signal-watcher` every 10 minutes. The periodic
check is mechanical, but Discord posting is not: posts happen only when new
signals cross the configured thresholds.

For launchd reliability, the installer copies the watcher script and config to
`~/.hermes/runtime/grok-signal-agent/` and points the LaunchAgent there instead
of the repository checkout. Re-run `scripts/install-macos-launchagent.sh` after
changing watcher code or `config/signal-watchers.json`.

`scripts/hermes-x-pulse-watcher.py` is the X/Twitter discussion watcher. X does
not provide a local push feed here, so it samples `x_search` every 30 minutes
through `com.shiraoku.grok-signal-agent.x-pulse-watcher`. First run primes
current X URLs; later runs trigger `x-buzz-trigger` only when the sample
contains new direct X/Twitter posts that pass the engagement filter. It
prioritizes the latest 120 minutes, can look back up to 240 minutes, and
qualifies candidates by likes, reposts, replies/quotes, views/impressions when
available, official or notable accounts with visible traction, or independent
same-topic posts that also have enough direct engagement. URL count alone is
not treated as buzz. It uses
`config/x-pulse-watchers.json`, route cooldowns, and the same signed webhook
delivery path as the feed watcher. The full X tech digest remains time-based
and is posted by Hermes cron in the morning, at lunch, and in the evening.

The default `signal-catchup` route is intentionally generic: an upstream
watcher decides that something changed, POSTs the event to
`/webhooks/signal-catchup`, and Hermes summarizes the payload into the
`tech-signals` channel. Zenn and wbsb.dev use dedicated routes and channels so
operational checks can see those sources separately. X pulse signals use
`x-buzz-trigger` and `#x-buzz-info` for short buzzing-post introductions. Full
tech digest, morning, and review posts are cron jobs because their value is
tied to a specific local time.

Setup outline:

```bash
# In ~/.hermes/.env, set HMAC secrets.
WEBHOOK_ENABLED=true
WEBHOOK_PORT=8644
WEBHOOK_SECRET=<global-secret>
HERMES_SIGNAL_CATCHUP_WEBHOOK_SECRET=<route-secret>
HERMES_POST_TRIGGER_WEBHOOK_SECRET=<post-trigger-route-secret>

scripts/register-hermes-webhooks.sh
scripts/hermes-signal-watcher.sh --dry-run --allow-first-run-send
scripts/hermes-x-pulse-watcher.sh --dry-run --allow-first-run-send
hermes webhook list
hermes gateway restart
```

Set `platforms.webhook.extra.host` in `~/.hermes/config.yaml` when the listener
must bind to `127.0.0.1`; Hermes v0.14.0 does not read `WEBHOOK_HOST` from
`.env`.

For a public callback URL, put a reverse proxy or tunnel in front of the
webhook listener and keep HMAC verification enabled. Do not expose a local Mac
gateway directly to the internet.
