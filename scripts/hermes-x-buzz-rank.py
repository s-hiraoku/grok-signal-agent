#!/usr/bin/env python3
"""Shared ranking / gating for the X buzz digest pipeline.

Community posts must actually be circulating, not merely topical.
Official watchlist posts can bypass the community score, but still need a
real status URL and a small sanity floor so dead tweets do not fill slots.

Buzz score:
    likes + 10*reposts + 5*replies + 6*quotes + views/100
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from dataclasses import dataclass, field
from typing import Iterable, List, Sequence, Set

STATUS_RE = re.compile(
    r"https?://(?:x\.com|twitter\.com)/(?:([^/?#\s]+)/status|i/web/status)/([0-9][0-9 ]{14,})",
    re.I,
)
BARE_STATUS_RE = re.compile(r"/status/([0-9][0-9 ]{14,})")
HANDLE_AT_RE = re.compile(r"@([A-Za-z0-9_]{1,30})")
METRIC_RE = re.compile(
    r"(likes|reposts|retweets|replies|quotes|views|impressions)"
    r"(?:\s*\+\s*(?:quotes|replies))?"
    r"\s*[=:：]?\s*([0-9][0-9,]*)",
    re.I,
)
REPLIES_QUOTES_RE = re.compile(
    r"replies\s*\+\s*quotes\s*[=:：]?\s*([0-9][0-9,]*)",
    re.I,
)
LEAK_RE = re.compile(
    r"NO_QUALIFIED_BUZZ|already_posted_status_ids|fresh_status_ids_seen|"
    r"The evidence|the prompt explicitly|The user wants|Let me carefully|"
    r"If nothing qualifies|the correct output is",
    re.I,
)
WORD_RE = re.compile(r"[a-z0-9]{3,}")

DEFAULT_OFFICIAL = (
    "OpenAI OpenAIDevs AnthropicAI claudeai SpaceX Google "
    "GoogleDeepMind GeminiApp xai GoogleAI"
)


@dataclass(frozen=True)
class RankConfig:
    min_score: int = 1500
    min_social_likes: int = 250
    min_social_reposts: int = 25
    official_min_likes: int = 20
    official_min_views: int = 2000
    max_topics: int = 4
    max_official: int = 2
    official_handles: Set[str] = field(default_factory=set)

    @classmethod
    def from_env(cls) -> "RankConfig":
        handles = {
            tok.strip().lstrip("@").lower()
            for tok in re.split(
                r"\s+",
                os.environ.get("HERMES_X_BUZZ_OFFICIAL_HANDLES", DEFAULT_OFFICIAL),
            )
            if tok.strip()
        }
        return cls(
            min_score=int(os.environ.get("HERMES_X_BUZZ_MIN_SCORE", "1500")),
            min_social_likes=int(os.environ.get("HERMES_X_BUZZ_MIN_SOCIAL_LIKES", "250")),
            min_social_reposts=int(os.environ.get("HERMES_X_BUZZ_MIN_SOCIAL_REPOSTS", "25")),
            official_min_likes=int(os.environ.get("HERMES_X_BUZZ_OFFICIAL_MIN_LIKES", "20")),
            official_min_views=int(os.environ.get("HERMES_X_BUZZ_OFFICIAL_MIN_VIEWS", "2000")),
            max_topics=int(os.environ.get("HERMES_X_BUZZ_MAX_TOPICS", "4")),
            max_official=int(os.environ.get("HERMES_X_BUZZ_MAX_OFFICIAL_TOPICS", "2")),
            official_handles=handles,
        )


@dataclass
class Metrics:
    likes: int = 0
    reposts: int = 0
    replies: int = 0
    quotes: int = 0
    views: int = 0

    @property
    def score(self) -> int:
        return int(
            self.likes
            + 10 * self.reposts
            + 5 * self.replies
            + 6 * self.quotes
            + self.views / 100
        )

    def has_any(self) -> bool:
        return any((self.likes, self.reposts, self.replies, self.quotes, self.views))


@dataclass
class Candidate:
    text: str
    status_ids: List[str]
    handle: str
    metrics: Metrics
    official: bool
    title: str = ""

    @property
    def score(self) -> int:
        return self.metrics.score

    @property
    def topic_key(self) -> Set[str]:
        source = self.title or self.text.splitlines()[0] if self.text else ""
        return set(WORD_RE.findall(source.lower()))


def _int_env_ids(raw: str) -> Set[str]:
    return {tok for tok in re.split(r"\s+", raw or "") if tok.isdigit() and len(tok) >= 15}


def normalize_id(raw: str) -> str:
    digits = re.sub(r"\D", "", raw or "")
    return digits if len(digits) >= 15 else ""


def parse_metrics(text: str) -> Metrics:
    metrics = Metrics()
    rq = REPLIES_QUOTES_RE.search(text or "")
    if rq:
        metrics.replies = int(rq.group(1).replace(",", ""))
    for name, num in METRIC_RE.findall(text or ""):
        value = int(num.replace(",", ""))
        key = name.lower()
        if key in {"retweets"}:
            metrics.reposts = max(metrics.reposts, value)
        elif key in {"impressions"}:
            metrics.views = max(metrics.views, value)
        elif key == "replies" and rq:
            continue
        elif hasattr(metrics, key):
            setattr(metrics, key, max(getattr(metrics, key), value))
    return metrics


def extract_ids(text: str) -> List[str]:
    ids: List[str] = []
    seen: Set[str] = set()
    for match in STATUS_RE.finditer(text or ""):
        status_id = normalize_id(match.group(2))
        if status_id and status_id not in seen:
            seen.add(status_id)
            ids.append(status_id)
    if not ids:
        for match in BARE_STATUS_RE.finditer(text or ""):
            status_id = normalize_id(match.group(1))
            if status_id and status_id not in seen:
                seen.add(status_id)
                ids.append(status_id)
    return ids


def extract_handle(text: str, official_handles: Set[str]) -> str:
    for match in STATUS_RE.finditer(text or ""):
        handle = (match.group(1) or "").strip()
        if handle and handle.lower() != "i":
            return handle
    ats = HANDLE_AT_RE.findall(text or "")
    for handle in ats:
        if handle.lower() in official_handles:
            return handle
    return ats[0] if ats else ""


def normalize_section(section: str) -> str:
    section = re.sub(r"https\s*:\s*//", "https://", section or "")
    section = re.sub(r"(https://(?:x|twitter))\.\s+com/", r"\1.com/", section, flags=re.I)
    section = re.sub(
        r"(https://(?:x|twitter)\.com/[A-Za-z0-9_]+)\s+(1[0-9]{14,})",
        r"\1/status/\2",
        section,
        flags=re.I,
    )
    section = STATUS_RE.sub(
        lambda m: f"https://x.com/{m.group(1) or 'i'}/status/{normalize_id(m.group(2))}",
        section,
    )
    kept = [line for line in section.splitlines() if not LEAK_RE.search(line)]
    return "\n".join(kept).strip() + "\n"


def community_qualifies(metrics: Metrics, cfg: RankConfig) -> bool:
    if not metrics.has_any():
        return False
    social = metrics.likes >= cfg.min_social_likes or metrics.reposts >= cfg.min_social_reposts
    return social and metrics.score >= cfg.min_score


def official_qualifies(metrics: Metrics, cfg: RankConfig) -> bool:
    if not metrics.has_any():
        # Brand-new official announcement may lack parsed metrics.
        return True
    return metrics.likes >= cfg.official_min_likes or metrics.views >= cfg.official_min_views


def qualifies(candidate: Candidate, cfg: RankConfig) -> bool:
    if not candidate.status_ids:
        return False
    if community_qualifies(candidate.metrics, cfg):
        return True
    if candidate.official and official_qualifies(candidate.metrics, cfg):
        return True
    return False


def _overlap(a: Set[str], b: Set[str]) -> int:
    return len(a & b)


def select_candidates(
    candidates: Sequence[Candidate],
    posted_ids: Set[str],
    cfg: RankConfig,
) -> List[Candidate]:
    usable: List[Candidate] = []
    used_ids: Set[str] = set()
    for cand in candidates:
        if any(status_id in posted_ids or status_id in used_ids for status_id in cand.status_ids):
            continue
        if not qualifies(cand, cfg):
            continue
        used_ids.update(cand.status_ids)
        usable.append(cand)

    usable.sort(
        key=lambda c: (
            c.score,
            c.metrics.likes,
            c.metrics.reposts,
            c.metrics.views,
        ),
        reverse=True,
    )

    selected: List[Candidate] = []
    official_bypass = 0
    for cand in usable:
        if len(selected) >= cfg.max_topics:
            break
        is_bypass = cand.official and not community_qualifies(cand.metrics, cfg)
        if is_bypass and official_bypass >= cfg.max_official:
            continue
        if any(_overlap(cand.topic_key, prev.topic_key) >= 3 for prev in selected):
            continue
        selected.append(cand)
        if is_bypass:
            official_bypass += 1
    return selected


def parse_digest_sections(text: str, cfg: RankConfig) -> List[Candidate]:
    chunks = re.split(r"(?=^### )", text or "", flags=re.M)
    out: List[Candidate] = []
    for chunk in chunks:
        if not chunk.startswith("###"):
            continue
        section = normalize_section(chunk)
        ids = extract_ids(section)
        if not ids:
            continue
        handle = extract_handle(section, cfg.official_handles)
        title = section.splitlines()[0][3:].strip() if section.startswith("###") else ""
        out.append(
            Candidate(
                text=section.strip() + "\n",
                status_ids=ids,
                handle=handle,
                metrics=parse_metrics(section),
                official=handle.lower() in cfg.official_handles,
                title=title,
            )
        )
    return out


def parse_evidence_posts(text: str, cfg: RankConfig) -> List[Candidate]:
    """Split a search-helper blob into per-post candidates around status URLs."""
    if not text:
        return []
    matches = list(STATUS_RE.finditer(text))
    if not matches:
        return []
    posts: List[Candidate] = []
    seen: Set[str] = set()
    for idx, match in enumerate(matches):
        start = matches[idx - 1].end() if idx else 0
        end = matches[idx + 1].start() if idx + 1 < len(matches) else len(text)
        window = text[max(start, match.start() - 280) : min(end, match.end() + 220)]
        section = normalize_section(window)
        ids = extract_ids(section)
        if not ids or ids[0] in seen:
            continue
        seen.add(ids[0])
        handle = extract_handle(section, cfg.official_handles) or (match.group(1) or "")
        posts.append(
            Candidate(
                text=section.strip() + "\n",
                status_ids=ids,
                handle=handle,
                metrics=parse_metrics(section),
                official=handle.lower() in cfg.official_handles,
                title=section.splitlines()[0][:120] if section.strip() else "",
            )
        )
    return posts


def render_digest(selected: Sequence[Candidate]) -> str:
    if not selected:
        return ""
    return "\n\n".join(c.text.strip("\n") for c in selected) + "\n"


def render_evidence(selected: Sequence[Candidate]) -> str:
    if not selected:
        return "NO_QUALIFIED_BUZZ\n"
    lines = ["# Ranked candidates (strongest first)", ""]
    for idx, cand in enumerate(selected, 1):
        kind = "official" if cand.official else "community"
        m = cand.metrics
        lines.append(
            f"{idx}. score={cand.score} {kind} @{cand.handle or 'unknown'} "
            f"status={cand.status_ids[0]} likes={m.likes} reposts={m.reposts} "
            f"replies={m.replies} views={m.views}"
        )
        url = f"https://x.com/{cand.handle or 'i'}/status/{cand.status_ids[0]}"
        snippet = " ".join(cand.text.split())
        if len(snippet) > 280:
            snippet = snippet[:277] + "..."
        lines.append(f"   {url}")
        lines.append(f"   {snippet}")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def select_digest(text: str, posted_ids: Iterable[str], cfg: RankConfig | None = None) -> str:
    cfg = cfg or RankConfig.from_env()
    posted = {normalize_id(i) for i in posted_ids if normalize_id(i)}
    selected = select_candidates(parse_digest_sections(text, cfg), posted, cfg)
    return render_digest(selected)


def filter_evidence(text: str, posted_ids: Iterable[str], cfg: RankConfig | None = None) -> str:
    cfg = cfg or RankConfig.from_env()
    posted = {normalize_id(i) for i in posted_ids if normalize_id(i)}
    selected = select_candidates(parse_evidence_posts(text, cfg), posted, cfg)
    return render_evidence(selected)


def _read(path: str) -> str:
    if path == "-":
        return sys.stdin.read()
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Rank and gate X buzz digest posts")
    parser.add_argument("mode", choices=["select", "evidence", "selftest"])
    parser.add_argument("--text-file", default="-")
    parser.add_argument("--posted-ids", default="")
    parser.add_argument("--posted-ids-file", default="")
    args = parser.parse_args(argv)

    if args.mode == "selftest":
        return 0 if _selftest() else 1

    posted = _int_env_ids(args.posted_ids)
    if args.posted_ids_file:
        posted |= _int_env_ids(_read(args.posted_ids_file))
    text = _read(args.text_file)
    cfg = RankConfig.from_env()
    if args.mode == "select":
        sys.stdout.write(select_digest(text, posted, cfg))
    else:
        sys.stdout.write(filter_evidence(text, posted, cfg))
    return 0


def _selftest() -> bool:
    cfg = RankConfig.from_env()
    digest = """
### Strong community launch
Foo shipped a real coding agent.
foo: shipping
https://x.com/foo/status/2090141955695198633
反応: likes=820 / reposts=25 / replies=87 / views=53835

### Weak filler repo
A quiet GitHub link.
tom_doerr: mcp server
https://x.com/tom_doerr/status/2089820032897323050
反応: likes=160 / reposts=16 / replies=0 / views=11363

### Official announcement
OpenAI posted a product update.
@OpenAI: zero data retention
https://x.com/OpenAI/status/2090165328290701800
反応: likes=40 / reposts=3 / replies=2 / views=4000

### Tiny noise
https://x.com/noise/status/2088742728888623445
反応: likes=10 / reposts=2 / replies=0 / views=585
""".strip()
    selected = select_digest(digest, [], cfg)
    ok = (
        "2090141955695198633" in selected
        and "2090165328290701800" in selected
        and "2089820032897323050" not in selected
        and "2088742728888623445" not in selected
    )
    if not ok:
        sys.stderr.write("selftest failed\n" + selected + "\n")
    return ok


if __name__ == "__main__":
    raise SystemExit(main())
