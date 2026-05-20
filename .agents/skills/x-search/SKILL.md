---
name: x-search
description: Use when searching X/Twitter posts, profiles, threads, reactions, rumors, or current discussion by delegating the lookup to Hermes Agent with its built-in x_search tool. Triggers on "X で検索", "ツイート検索", "X で何て言われてる", "search X for", "what's the buzz on X about", and @handle recent-post lookups.
---

# x-search

Delegate X (Twitter) search to Hermes Agent's `x_search` toolset. Hermes runs as a one-shot subprocess and returns results via stdout.

## Required Command Shape

Run Hermes in oneshot mode with only the `x_search` toolset enabled:

```bash
~/.local/bin/hermes -t x_search -z '<prompt>'
```

This root-level `-z` / `--oneshot` form prints only the final response text. Do not omit `-t x_search`; otherwise Hermes may choose non-X tools.

## Prompt Template

The prompt must constrain Hermes to `x_search` and forbid `xurl`:

```text
Use x_search to search X/Twitter for: <query>.
Do not use xurl. Do not use web_search or browser tools.
If the request includes @handles, use allowed_x_handles where appropriate.
If the request includes dates, apply from_date/to_date in YYYY-MM-DD.
Return: concise findings, notable posts/accounts, and source URLs/citations.
```

## Handling User Filters

Translate natural-language filters into the prompt before calling Hermes:

- `@handle` filters to include -> tell Hermes to use `allowed_x_handles`.
- Explicit exclusions -> tell Hermes to use `excluded_x_handles`.
- Relative dates such as "today", "yesterday", "this week", "今日", or "今週" -> resolve to exact `YYYY-MM-DD` dates before calling Hermes.
- Media-bearing posts -> ask Hermes to enable image or video understanding only when relevant.

Keep the initial query narrow. If results are too broad, run a second Hermes query with tighter terms or date bounds rather than expanding the toolset.

## Reporting Back To The User

- Summarize Hermes output in the user's language.
- Include direct X post URLs or citations when Hermes provides them. Do not synthesize URLs.
- If Hermes reports missing xAI credentials or unavailable `x_search`, tell the user to run:

  ```bash
  ~/.local/bin/hermes auth add xai-oauth
  ```

  Then stop. Do not inspect credential files and do not fall back to `xurl`, web search, or browser-based X readers.

## What This Skill Is Not

- Not for fetching a known X URL's contents.
- Not for general web search.
- Not for posting to X.
