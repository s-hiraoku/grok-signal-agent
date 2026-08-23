#!/usr/bin/env python3
"""Direct x_search helper for hermes-x-buzz-digest-cron.sh.

Bypasses agent tool-calling (which has been unreliable for one-shot cron runs)
by calling Hermes' x_search_tool implementation directly, then returning a
compact evidence pack for a separate summarizer step.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime, timedelta, timezone
from importlib.machinery import SourceFileLoader
from pathlib import Path
from typing import Any, Dict, List, Set, Tuple

STATUS_RE = re.compile(
    r"https?://(?:x\.com|twitter\.com)/(?:[^/\s]+/status|i/web/status)/(\d+)",
    re.I,
)
BARE_STATUS_RE = re.compile(r"/status/(\d+)")
DEBUG_PATH = Path.home() / ".hermes" / "state" / "x-buzz-digests" / ".last-search.json"
RANK_HELPER = Path(__file__).with_name("hermes-x-buzz-rank.py")

OFFICIAL_HANDLES = [
    "OpenAI",
    "OpenAIDevs",
    "AnthropicAI",
    "claudeai",
    "SpaceX",
    "Google",
    "GoogleDeepMind",
    "GeminiApp",
    "xai",
    "GoogleAI",
]

SEARCHES = [
    {
        "label": "AI / tools / Web / infra",
        "query": (
            "AI OR LLM OR Claude OR OpenAI OR Codex OR Anthropic OR Grok OR MCP "
            'OR TypeScript OR React OR GitHub OR Cloudflare OR CVE OR "coding agent" '
            "OR from:OpenAI OR from:AnthropicAI OR from:SpaceX OR from:GeminiApp "
            "OR from:GoogleDeepMind OR from:xai"
        ),
        "handles": None,
        "kind": "buzz",
    },
    {
        "label": "Official accounts",
        "query": (
            "original posts from official OpenAI, Anthropic, Claude, SpaceX, "
            "Google, Gemini, DeepMind, or xAI accounts"
        ),
        "handles": OFFICIAL_HANDLES,
        "kind": "official",
    },
]


def _load_exclude_ids(path: str | None) -> Set[str]:
    if not path:
        return set()
    p = Path(path)
    if not p.exists():
        return set()
    ids: Set[str] = set()
    for line in p.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = line.strip()
        if line.isdigit():
            ids.add(line)
    return ids


def _extract_ids(text: str) -> List[str]:
    ids: List[str] = []
    for m in STATUS_RE.finditer(text or ""):
        ids.append(m.group(1))
    if not ids:
        for m in BARE_STATUS_RE.finditer(text or ""):
            ids.append(m.group(1))
    seen: Set[str] = set()
    out: List[str] = []
    for i in ids:
        if i not in seen:
            seen.add(i)
            out.append(i)
    return out


def _filter_excluded(text: str, excluded: Set[str]) -> str:
    if not excluded:
        return text
    kept: List[str] = []
    for line in (text or "").splitlines():
        ids = _extract_ids(line)
        if ids and all(i in excluded for i in ids):
            continue
        kept.append(line)
    return "\n".join(kept).strip()


def _import_x_search():
    candidates = [
        Path.home() / ".hermes" / "hermes-agent",
        Path("/Users/hiraoku.shinichi/.hermes/hermes-agent"),
    ]
    for root in candidates:
        if (root / "tools" / "x_search_tool.py").exists():
            sys.path.insert(0, str(root))
            break
    from tools.x_search_tool import x_search_tool  # type: ignore

    return x_search_tool


def _citation_urls(data: Dict[str, Any]) -> List[str]:
    urls: List[str] = []
    for c in data.get("citations") or []:
        if isinstance(c, dict):
            url = str(c.get("url") or "").strip()
        else:
            url = str(c).strip()
        if url:
            urls.append(url)
    for item in data.get("inline_citations") or []:
        if isinstance(item, dict):
            url = str(item.get("url") or "").strip()
        else:
            url = str(item).strip()
        if url:
            urls.append(url)
    return urls


def _parse_search(raw: str) -> Dict[str, Any]:
    try:
        data = json.loads(raw)
        if isinstance(data, dict):
            return data
    except Exception:
        pass
    return {"answer": str(raw), "citations": [], "inline_citations": []}


def _run_one(
    x_search_tool,
    prompt: str,
    from_date: str,
    to_date: str,
    allowed_handles: List[str] | None = None,
) -> Dict[str, Any]:
    kwargs: Dict[str, Any] = {"query": prompt}
    if from_date:
        kwargs["from_date"] = from_date
    if to_date:
        kwargs["to_date"] = to_date
    if allowed_handles:
        kwargs["allowed_x_handles"] = allowed_handles
    raw = x_search_tool(**kwargs)
    parsed = _parse_search(raw)
    parsed["_raw_preview"] = str(raw)[:4000]
    return parsed


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--window-hours", type=int, default=13)
    parser.add_argument("--from-date", default="")
    parser.add_argument("--to-date", default="")
    parser.add_argument("--exclude-ids-file", default="")
    parser.add_argument("--out", default="")
    args = parser.parse_args()

    now = datetime.now(timezone.utc)
    if args.from_date.strip():
        from_date = args.from_date.strip()
    else:
        from_date = (now - timedelta(hours=max(1, args.window_hours))).date().isoformat()
    to_date = args.to_date.strip() or now.date().isoformat()

    excluded = _load_exclude_ids(args.exclude_ids_file)
    x_search_tool = _import_x_search()

    blocks: List[str] = []
    all_ids: Set[str] = set()
    debug: Dict[str, Any] = {
        "window_hours": args.window_hours,
        "from_date": from_date,
        "to_date": to_date,
        "excluded_count": len(excluded),
        "attempts": [],
    }

    for spec in SEARCHES:
        label = str(spec["label"])
        query = str(spec["query"])
        handles = spec.get("handles")
        kind = str(spec.get("kind") or "buzz")
        if kind == "official":
            engagement_rule = (
                "These are official watchlist accounts. Include original posts from the "
                "last window even if engagement is still modest. Prefer announcements, "
                "launches, model/product updates, research, and changelogs. Skip replies "
                "and quote-only fluff. Still include likes/reposts/replies/views when visible."
            )
            max_posts = 6
        else:
            engagement_rule = (
                "Include only posts that are actually circulating right now. "
                "Require visible social proof: likes>=250 or reposts>=25, AND a strong "
                "combined buzz score likes + 10*reposts + 5*replies + views/100 of at least 1500. "
                "Skip low-engagement filler, repo dumps, and posts that only barely have "
                "80 likes or 10k views. Prefer the strongest few posts, not a long list."
            )
            max_posts = 8
        prompt = (
            f"Find circulating X/Twitter posts from roughly the last {args.window_hours} hours "
            f"about: {label}.\n"
            f"Search query guidance: {query}\n"
            f"{engagement_rule}\n"
            "Prefer original posts. For each useful post, include: account handle, one-line "
            "summary, a direct https://x.com/.../status/... URL, and likes/reposts/replies/views "
            "if visible.\n"
            f"Return at most {max_posts} posts. Always include real status URLs. Do not invent URLs."
        )
        attempts: List[Tuple[str, str, str]] = [
            ("dated", from_date, to_date),
            ("no-date-filter", "", ""),
        ]
        chosen: Dict[str, Any] | None = None
        for attempt_name, attempt_from, attempt_to in attempts:
            try:
                parsed = _run_one(
                    x_search_tool,
                    prompt,
                    attempt_from,
                    attempt_to,
                    allowed_handles=list(handles) if handles else None,
                )
            except Exception as exc:  # noqa: BLE001
                debug["attempts"].append({"name": attempt_name, "error": str(exc)})
                continue
            urls = _citation_urls(parsed)
            answer = str(parsed.get("answer") or parsed.get("text") or "").strip()
            ids = set(_extract_ids(answer))
            for url in urls:
                ids.update(_extract_ids(url))
            debug["attempts"].append(
                {
                    "name": attempt_name,
                    "from_date": attempt_from,
                    "to_date": attempt_to,
                    "error": parsed.get("error"),
                    "degraded": bool(parsed.get("degraded")),
                    "degraded_reason": parsed.get("degraded_reason"),
                    "answer_chars": len(answer),
                    "citation_urls": urls[:20],
                    "status_ids": sorted(ids),
                    "answer_preview": answer[:800],
                }
            )
            if parsed.get("error"):
                continue
            if ids or any(_extract_ids(u) for u in urls):
                chosen = parsed
                break
            if chosen is None:
                chosen = parsed

        if chosen is None:
            blocks.append(f"## {label}\nERROR: x_search returned no usable result")
            continue
        if chosen.get("error"):
            blocks.append(f"## {label}\nERROR: {chosen.get('error')}")
            continue

        answer = str(chosen.get("answer") or chosen.get("text") or "").strip()
        citations = _citation_urls(chosen)
        degraded = bool(chosen.get("degraded"))
        filtered = _filter_excluded(answer, excluded)
        cite_lines = []
        for c in citations:
            ids = _extract_ids(c)
            if ids and all(i in excluded for i in ids):
                continue
            cite_lines.append(c)
            all_ids.update(ids)
        found_ids = _extract_ids(filtered)
        all_ids.update(found_ids)

        if not filtered and not cite_lines:
            blocks.append(f"## {label}\n(no fresh posts after dedupe)")
            continue

        part = [f"## {label}"]
        if degraded:
            part.append("(note: provider marked result degraded / possibly unsourced)")
        if filtered:
            part.append(filtered)
        if cite_lines:
            part.append("Citations:")
            part.extend(f"- {c}" for c in cite_lines[:12])
        blocks.append("\n".join(part))

    useful = any(
        ("https://x.com/" in b.lower() or "https://twitter.com/" in b.lower())
        and "no fresh posts" not in b.lower()
        and not b.strip().endswith("ERROR:")
        for b in blocks
    )
    if not useful:
        useful = bool(all_ids - excluded)

    ranked = ""
    if useful and RANK_HELPER.exists():
        try:
            rank = SourceFileLoader("hermes_x_buzz_rank", str(RANK_HELPER)).load_module()
            ranked = rank.filter_evidence("\n\n".join(blocks), excluded).strip()
        except Exception as exc:  # noqa: BLE001
            debug["rank_error"] = str(exc)
            ranked = ""
        if ranked and not ranked.startswith("NO_QUALIFIED_BUZZ"):
            useful = True
            debug["ranked"] = True
        else:
            debug["ranked"] = False

    debug["fresh_status_ids"] = sorted(all_ids - excluded)
    debug["useful"] = useful
    debug["ranked_preview"] = ranked[:800]

    if not useful:
        out = "NO_QUALIFIED_BUZZ\n"
    else:
        header = [
            f"window_hours={args.window_hours}",
            f"from_date={from_date}",
            f"to_date={to_date}",
            f"excluded_status_ids={len(excluded)}",
            f"fresh_status_ids_seen={len(all_ids - excluded)}",
            "",
        ]
        if ranked and not ranked.startswith("NO_QUALIFIED_BUZZ"):
            body = "\n".join(header + [ranked])
        else:
            body = "\n\n".join(header + blocks)
        out = body.strip() + "\n"

    try:
        DEBUG_PATH.parent.mkdir(parents=True, exist_ok=True)
        DEBUG_PATH.write_text(json.dumps(debug, ensure_ascii=False, indent=2), encoding="utf-8")
    except OSError:
        pass

    if args.out:
        Path(args.out).write_text(out, encoding="utf-8")
    else:
        sys.stdout.write(out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
