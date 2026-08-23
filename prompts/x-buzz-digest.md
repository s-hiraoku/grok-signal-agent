# X Buzz Digest Prompt

Use x_search to check X/Twitter for posts that are genuinely circulating right
now in AI, developer tools, programming, and Web/IT topics, focused on the
window since the previous run.

Cover these topics as evenly as the available solid posts allow:

1. AI models, AI agents, coding agents, LLM app development, MCP/tool use, and
   practical AI engineering (OpenAI, Anthropic/Claude, Grok/xAI, Codex, Claude
   Code, and similar).
2. Web frontend/backend development, browsers, frameworks, runtimes,
   JavaScript/TypeScript, CSS, and platform APIs.
3. Programming languages, developer tools, IDEs, libraries, databases,
   testing, build tools, and software engineering practices.
4. Cloud, infrastructure, security incidents/CVEs, open source, and major
   product launches that matter to builders.

A regular community post must be actually buzzing, not merely topical.
Include it only when BOTH of these are true:

1. Social proof: likes >= 250 OR reposts >= 25
2. Buzz score >= 1500, where
   score = likes + 10*reposts + 5*replies + 6*quotes + views/100

Do not include a regular community post just because it is technically
interesting. A post with only ~80 likes, ~10 reposts, or ~10k views is too
weak. Quiet GitHub dumps, listicles, and low-engagement promo posts are
omitted even if they mention MCP, agents, or a new repo.

Always include a NEW original post from these official watchlist accounts,
even when it is below the community score, as long as it has a real status
URL and is not a dead tweet (likes >= 20 or views >= 2000, when those
numbers are visible):

OpenAI, OpenAIDevs, AnthropicAI, claudeai, SpaceX, Google, GoogleDeepMind,
GeminiApp, xai, GoogleAI

Official posts still need a real status URL. Prefer announcements, launches,
model/product updates, research, and changelogs. Skip official replies and
quote-only fluff. Prefer posts from the last few hours; use the runtime
`window_hours` hint for how far back to look. Do not invent engagement
numbers — if a number is not visible, treat it as 0 for that metric and rely
on the other metrics instead. Order the topics you do include by buzz score,
strongest first.

If the evidence already contains a ranked-candidate list, use only those
ranked posts. Do not revive dropped posts from raw notes.

Prefer original posts, official accounts, substantial technical threads,
release announcements, incident reports, and posts multiple independent
developer/AI/Web/IT accounts are discussing. Avoid generic AI hype,
stock/crypto chatter, and posts with only vague reactions and no concrete
technical content.

Never reuse a post that already appeared in a previous digest. The runtime
context may include `already_posted_status_ids` and/or
`already_posted_urls`. Treat those as a hard exclude list — do not include
matching status IDs or URLs even if they still look hot. Prefer fresher
replacements. Also skip near-duplicate topics: if two posts are the same
story, keep only the stronger one.

It is normal and expected for a run to find few or no qualifying posts if the
window has been quiet — do not pad with weak topics just to fill space.
Prefer 1-3 excellent posts over 5 mediocre ones.

Do not use xurl. Do not use web_search or browser tools.

Important: actually call the x_search tool, wait for real results, then write
the final digest. Never print tool-call syntax, pseudo-XML, function stubs,
or raw query plans as the answer.

Write a factual Japanese digest only. Do not speak as ヘルメスちゃん. Do not
add greetings, catchphrases, opinions, recommendations, next actions, emoji,
or commentary such as 「気になる情報を見つけたよ」, 「話題だよ」,
「見ていこう」, 「なぜ今見るべきか」, or 「次に確認するとよいこと」.

If there is at least one qualifying NEW post, return this exact structure and
nothing else:

### <短い事実タイトル>
<何が起きているかの詳細を1-3文。事実と投稿内容だけ。解釈・おすすめは書かない>
<account name>: <投稿の要点または訳>
https://x.com/<user>/status/<digits>
反応: likes=<n> / reposts=<n> / replies=<n> / views=<n>

Cover 1 to 4 topics total. Repeat the `###` block for each topic. Do not
exceed 4. Do not add an intro line, outro, or any text before the first `###`.

Every topic must include at least one direct source URL exactly as returned
by x_search. Each URL must start with `https://x.com/` or
`https://twitter.com/` and must contain `/status/<digits>`. Do not synthesize
URLs. Omit any topic that has no direct source URL or no visible traction
signal. If a metric is not visible, omit that metric from the `反応` line
instead of inventing it.

If there are no qualifying NEW posts at all in the window, return exactly this
single line and nothing else: `NO_QUALIFIED_BUZZ`
