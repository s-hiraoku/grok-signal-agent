# ヘルメスちゃん Self-Growth

This repo treats "self-growth" as an operational loop, not as real
consciousness. ヘルメスちゃん keeps a persistent identity, memory,
self-evaluations, and weekly improvement notes, then uses them as soft guidance
for later digests.

## What Runs

The event-triggered digest handler does five things:

1. Reads identity from `~/.hermes/prompts/hermes-chan-identity.md`.
2. Reads self-memory from `~/.hermes/state/hermes-chan-memory.md`.
3. Saves each digest under `~/.hermes/state/digests/`.
4. Lints each digest and saves metadata/quality reports under
   `~/.hermes/state/digest-metadata/` and
   `~/.hermes/state/digest-quality/`.
5. Evaluates each digest and saves the result under
   `~/.hermes/state/evaluations/`.

A Hermes webhook trigger can run the dreaming memory recomposition handler when
an upstream event source asks for it. It reads recent conversation excerpts, digests,
evaluations, explicit feedback, built-in Hermes memories, and prior
reflections, then saves:

```text
~/.hermes/state/dreaming/<ts>.md
```

The raw inputs are not deleted. The job replaces only the current working
memory view:

```text
~/.hermes/state/hermes-chan-memory.md
```

with the recomposed `# ヘルメスちゃんの自己メモリ` section from the report.
This is designed as reinterpretation and synthesis, not forgetting.

A weekly LaunchAgent runs on Sunday at 21:10 local time. It reads recent
evaluations and rewrites:

```text
~/.hermes/state/hermes-chan-memory.md
```

That memory is then included in future digest prompts.

## Files

- `prompts/hermes-chan-identity.md`: stable identity, values, and voice.
- `prompts/hermes-post-style.md`: Discord posting voice that takes priority
  over older self-memory tone notes when producing user-visible posts.
- `prompts/evaluate-digest.md`: per-digest self-evaluation rubric.
- `prompts/nightly-dreaming.md`: nightly memory recomposition prompt.
- `prompts/weekly-self-reflection.md`: weekly memory update prompt.
- `prompts/tech-digest.md`: prompt used by the `tech-digest` handler.
- `config/hermes-webhooks.json`: declarative webhook trigger/channel registry.
- `config/hermes-cronjobs.json`: active time-based review jobs plus disabled
  legacy cron registry used to remove old posting cron jobs by name.
- `scripts/register-hermes-webhooks.sh`: creates or updates Hermes webhook
  subscriptions from the JSON registry.
- `scripts/register-hermes-cronjobs.sh`: syncs active Hermes cron jobs and
  removes disabled legacy jobs from the JSON registry.
- `scripts/hermes-tech-digest-cron.sh`: implementation script run by the
  scheduled tech digest cron jobs and manual `tech-digest-trigger` route; it
  generates, saves, lints, evaluates, and prints the digest for Hermes delivery.
- `scripts/hermes-dreaming-cron.sh`: nightly recomposition script; it saves a
  reviewable dreaming report and refreshes the current working memory view.
- `scripts/hermes-weekly-self-reflection.sh`: weekly memory update.
- `scripts/hermes-gbrain-retrieval.sh`: prints high-priority guidance from
  prior digests/evaluations plus user notes, feedback, and follow-up requests.
- `scripts/hermes-digest-lint.sh`: validates generated digest structure and
  writes machine-readable metadata for duplicate/topic-balance analysis.
- `scripts/hermes-discord-feedback.sh`: captures explicit Discord feedback or
  follow-up requests as local artifacts and optional gbrain pages.
- `scripts/hermes-alert.sh`: logs and optionally forwards operational alerts.
- `launchd/com.shiraoku.grok-signal-agent.weekly-self-reflection.plist`:
  weekly schedule.

## Operating Notes

Install or refresh the LaunchAgents after pulling these files:

```bash
./scripts/install-macos-launchagent.sh
```

Check self-growth logs:

```bash
tail -f ~/.hermes/logs/gateway.log ~/.hermes/logs/gateway.error.log
tail -f ~/.hermes/logs/hermes-dreaming.log
tail -f ~/.hermes/logs/hermes-weekly-self-reflection.log
```

Inspect memory:

```bash
sed -n '1,220p' ~/.hermes/state/hermes-chan-memory.md
```

Run weekly reflection manually:

```bash
~/.hermes/bin/hermes-weekly-self-reflection.sh
```

Run nightly dreaming manually:

```bash
~/.hermes/scripts/hermes-dreaming-cron.sh
```

## Safety Boundary

ヘルメスちゃん may update runtime memory, but she does not rewrite this
repository or change LaunchAgents by herself. Code, prompts in this repo, and
service schedules remain human-reviewed.

## gbrain Integration Design

`garrytan/gbrain` is the planned long-term memory backend. It provides a
Markdown-backed brain (a git "brain repo"), hybrid search (pgvector HNSW + BM25
+ reciprocal-rank fusion), synthesized cited answers, a self-wiring knowledge
graph with typed edges, gap analysis, and an MCP server exposing 30+ tools.

The current loop already produces exactly the raw material gbrain wants:
identity, per-digest curation, per-digest self-evaluation, and weekly memory
rewrites. This section specifies how those flow into gbrain.

### Deployment Target

- Runtime: TypeScript / Bun. gbrain runs as a separate process from Hermes
  cron and weekly reflection jobs.
- Storage: embedded Postgres via PGLite, initialized once with
  `gbrain init --pglite`. No external database to operate.
- Access: stdio MCP, single machine. Register it with Claude Code via
  `claude mcp add gbrain -- gbrain serve`. No HTTP server, OAuth, or remote
  surface in this phase.
- Brain repo: a git repository of Markdown pages, kept separate from this
  code repo. Suggested location: `~/.hermes/brain` (git-managed,
  `gbrain`-synced into PGLite).

### What Becomes a Page

The loop's existing artifacts map onto gbrain page types as follows. Each
already carries `---` frontmatter, so the mapping is mechanical.

| Source artifact                         | gbrain page type | Key fields to carry over                          |
| --------------------------------------- | ---------------- | ------------------------------------------------- |
| `state/digests/<ts>.md`                 | `digest`         | `created_at`, `digest_prefix`, source X URLs      |
| `state/evaluations/<ts>.md`             | `evaluation`     | `created_at`, `digest_file`, scores, improvements |
| `state/weekly-reflections/<ts>.md`      | `reflection`     | `created_at`, the rewritten memory snapshot       |
| `state/user-feedback/<ts>.md`           | `feedback` / `followup` | `created_at`, user/channel IDs, explicit request |
| `prompts/hermes-chan-identity.md`       | `identity`       | stable identity (written once, rarely updated)    |

Entities to extract into graph edges (gbrain does this with zero LLM calls):
each digest section's X/Twitter account and the topic/title become nodes, with
edges like `digest -> mentions -> account` and `digest -> covers -> topic`.
Over time this answers questions like "which accounts repeatedly surface MCP
news" and "what topics are we over-covering".

### Phased Rollout

Ordered so each phase is useful on its own and reversible.

1. **Bootstrap, read-only.** Stand up gbrain with PGLite and the stdio MCP
   server. Backfill existing `~/.hermes/state/digests` and `evaluations` as
   `digest` / `evaluation` pages via `scripts/hermes-gbrain-backfill.sh`. No
   change to trigger jobs yet. Validate keyword search by hand.
   Hybrid (vector) search needs an embedding provider key (OpenAI / Voyage /
   ZeroEntropy); the bootstrap defaults to `--no-embedding` so it runs with no
   key, and embeddings are enabled in Phase 2 once a key is available
   (`gbrain config set embedding_model …`, then `gbrain embed --all`).

2. **Retrieval injection.** Before building the digest prompt, query gbrain
   for the most relevant prior digests/evaluations for the upcoming window and
   inject a short "what we already covered / what scored poorly" block as soft
   guidance — augmenting the flat `memory_context` read. This is read-only
   against the brain and is the highest-value, lowest-risk win.

   Implemented by `scripts/hermes-gbrain-retrieval.sh`, which prints a Japanese
   guidance block (recent digest headlines to avoid repeating + the latest
   self-evaluation's "次回の改善指示" bullets) and stays silent on any failure.
   The digest job injects it only when `HERMES_GBRAIN_RETRIEVAL=1`; unset, the
   prompt is unchanged. The helper defaults to keyword search (`gbrain search`,
   no embedding key needed) and switches to hybrid search with
   `GBRAIN_SEARCH_MODE=query` once embeddings are configured:

   ```bash
   export OPENAI_API_KEY=sk-…           # or VOYAGE_API_KEY / ZEROENTROPY_API_KEY
   ( cd ~/.hermes/brain && gbrain config set embedding_model openai:text-embedding-3-large )
   ( cd ~/.hermes/brain && gbrain embed --all )
   # then run the digest job with:
   #   HERMES_GBRAIN_RETRIEVAL=1 GBRAIN_SEARCH_MODE=query
   ```

3. **Automatic write-back (append).** After a digest is sent and evaluated,
   the digest job writes the digest and its evaluation into the brain via
   `gbrain put <slug>` (content piped on stdin with `type`/`slug`/`created_at`
   frontmatter). Slugs reuse the backfill convention — `digest-<timestamp>` /
   `evaluation-<timestamp>` — so a write-back and a later backfill of the same
   `state/` file upsert the same page rather than duplicating it. This step is
   append/upsert only; it never deletes pages.

   Gated behind `HERMES_GBRAIN_WRITEBACK=1`; unset, the digest job does not
   touch the brain. The write-back is defensive: a missing gbrain binary,
   missing brain, or a failed `put` is logged and ignored so curation and
   delivery are never blocked. (Note: `gbrain put` only creates a page when the
   slug looks like a real content slug; the timestamped slugs we use work,
   while ad-hoc test slugs may be rejected — verified during implementation.)

4. **Full automation (append + update).** The weekly reflection, after
   rewriting the flat memory file, also reconciles the brain
   (`scripts/hermes-weekly-self-reflection.sh`, gated behind
   `HERMES_GBRAIN_RECONCILE=1`):

   1. upsert the reflection as a `learnings-<timestamp>` page
      (`type: reflection`) so recurring learnings accumulate in the brain;
   2. `gbrain export --dir ~/.hermes/brain/pages` and `git commit` the result,
      so every enrichment write is revertable;
   3. `gbrain dream --dir …` once — the overnight maintenance cycle (lint,
      back-links, consolidate, emotional-weight recompute, etc.).

   Each step is defensive: a failure is logged and ignored so the flat memory
   update is never blocked. Unset, the weekly job behaves exactly as before.

   **Storage-model correction.** Contrary to the original assumption, gbrain's
   *primary* store is the PGLite DB created by `gbrain init` (under
   `~/.gbrain/`), not a git repo of markdown. The markdown "brain repo" is a
   **derived export** (`gbrain export`). `list`/`get`/`search`/`put` operate on
   the DB; `gbrain dream` (and `extract --source fs`) operate on the exported
   markdown directory, which is why the weekly reconcile exports first. Until
   the digest corpus develops `[[wikilinks]]` between pages, `dream` reports all
   pages as orphans and the consolidate/back-link steps are no-ops — Phase 4 is
   wired up but only pays off once the corpus is larger and interlinked.

### Revised Safety Boundary for the Brain

The Safety Boundary above (ヘルメスちゃん updates runtime memory but does not
rewrite this repo or the LaunchAgents) still holds for the **code** repository.
With full write-back enabled, the boundary is restated for the brain:

- **She may write.** The brain (PGLite DB under `~/.gbrain/`) and its exported
  markdown view (`~/.hermes/brain/pages`) are runtime memory. ヘルメスちゃん may
  create, link, update, dedupe, and enrich pages there automatically, including
  the weekly `learnings` page and `dream`-driven enrichment.
- **She may not write.** This code repository (`scripts/`, `prompts/`,
  `launchd/`, `docs/`), the LaunchAgents, and the gbrain deployment
  configuration remain human-reviewed. She does not change her own schedule,
  prompts, or runtime.
- **Recoverability.** The DB is not the only copy: the weekly reconcile exports
  to `~/.hermes/brain/pages` and `git commit`s it before running `dream`, so
  every enrichment cycle is a commit recoverable with `git revert`. The
  original `state/` Markdown files remain the source of truth and can re-backfill
  the brain from scratch at any time.

### Operating Notes (when adopted)

```bash
# one-time
bun install -g github:garrytan/gbrain
gbrain init --pglite                 # creates embedded Postgres (PGLite)
claude mcp add gbrain -- gbrain serve   # serve = stdio MCP server

# backfill existing state into the brain (phase 1)
scripts/hermes-gbrain-backfill.sh    # stages state/*.md with type+slug, imports
```

The real gbrain CLI has no `import --type` flag: page **type** lives in each
file's YAML frontmatter, and `import <dir>` ingests a directory of such files.
Our `state/` digests and evaluations carry `created_at` but no `type`/`slug`,
so the backfill script stages copies with a `type:` (and a stable `slug:`
derived from the timestamp) added to the frontmatter, then runs
`gbrain import <staging-dir>`. Page writes use `gbrain put <slug> --content …`;
hybrid retrieval uses `gbrain query "<question>"`.

Do not advance past a phase until the previous one has proven useful in
practice. gbrain adds another runtime, storage model, and operational surface
area; each phase should earn the next.
