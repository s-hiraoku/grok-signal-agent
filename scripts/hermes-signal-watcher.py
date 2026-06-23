#!/usr/bin/env python3
"""Detect meaningful source changes and trigger Hermes webhooks.

The watcher is intentionally separate from Hermes. It polls source feeds/pages,
dedupes items, scores new signals, and POSTs only threshold-crossing payloads
to Hermes webhook routes.
"""

from __future__ import annotations

import argparse
import difflib
import email.utils
import hashlib
import hmac
import html
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from datetime import datetime, timezone
from html.parser import HTMLParser
from pathlib import Path
from typing import Any


def expand_path(value: str) -> Path:
    return Path(os.path.expandvars(os.path.expanduser(value)))


def now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def normalize_space(value: str) -> str:
    return re.sub(r"\s+", " ", html.unescape(value or "")).strip()


def slug_key(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:24]


def load_env_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return values
    for raw_line in lines:
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
            value = value[1:-1]
        if key:
            values[key] = value
    return values


def env_value(name: str, env_file_values: dict[str, str]) -> str:
    if not name:
        return ""
    return os.environ.get(name) or env_file_values.get(name, "")


@dataclass
class SignalItem:
    source_id: str
    source_url: str
    item_id: str
    title: str
    url: str
    summary: str = ""
    published_at: str = ""
    author: str = ""
    tags: list[str] | None = None

    @property
    def stable_key(self) -> str:
        return f"{self.source_id}:{self.item_id or self.url}"


def load_json(path: Path, default: Any) -> Any:
    if not path.exists():
        return default
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return default


def save_json(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(path)


def fetch_text(url: str, timeout: int, user_agent: str) -> str:
    if url.startswith("file://"):
        return Path(urllib.parse.urlparse(url).path).read_text(encoding="utf-8")
    req = urllib.request.Request(url, headers={"User-Agent": user_agent})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read()
        charset = resp.headers.get_content_charset() or "utf-8"
        return raw.decode(charset, errors="replace")


class LinkCollector(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.links: list[tuple[str, str]] = []
        self._current_href: str | None = None
        self._current_text: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag.lower() != "a" or self._current_href is not None:
            return
        href = ""
        for name, value in attrs:
            if name.lower() == "href" and value:
                href = value
                break
        if href:
            self._current_href = href
            self._current_text = []

    def handle_data(self, data: str) -> None:
        if self._current_href is not None:
            self._current_text.append(data)

    def handle_endtag(self, tag: str) -> None:
        if tag.lower() != "a" or self._current_href is None:
            return
        self.links.append((self._current_href, " ".join(self._current_text)))
        self._current_href = None
        self._current_text = []


class TextCollector(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []
        self._skip_depth = 0

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag.lower() in {"script", "style", "noscript", "svg"}:
            self._skip_depth += 1
            return
        if self._skip_depth:
            return
        if tag.lower() in {"p", "br", "li", "h1", "h2", "h3", "h4", "section", "article", "div"}:
            self.parts.append("\n")

    def handle_endtag(self, tag: str) -> None:
        if tag.lower() in {"script", "style", "noscript", "svg"} and self._skip_depth:
            self._skip_depth -= 1
            return
        if self._skip_depth:
            return
        if tag.lower() in {"p", "li", "h1", "h2", "h3", "h4", "section", "article", "div"}:
            self.parts.append("\n")

    def handle_data(self, data: str) -> None:
        if not self._skip_depth:
            self.parts.append(data)

    def text(self) -> str:
        lines = [normalize_space(part) for part in "".join(self.parts).splitlines()]
        return "\n".join(line for line in lines if line)


def child_text(node: ET.Element, names: tuple[str, ...]) -> str:
    for child in list(node):
        local = child.tag.rsplit("}", 1)[-1].lower()
        if local in names and child.text:
            return normalize_space(child.text)
    return ""


def first_link(node: ET.Element) -> str:
    for child in list(node):
        local = child.tag.rsplit("}", 1)[-1].lower()
        if local != "link":
            continue
        href = child.attrib.get("href")
        if href:
            return href.strip()
        if child.text:
            return normalize_space(child.text)
    return ""


def parse_feed(source: dict[str, Any], text: str) -> list[SignalItem]:
    root = ET.fromstring(text)
    source_id = source["id"]
    source_url = source["url"]
    items: list[SignalItem] = []

    nodes = [
        n for n in root.iter()
        if n.tag.rsplit("}", 1)[-1].lower() in {"item", "entry"}
    ]
    for node in nodes:
        title = child_text(node, ("title",))
        link = first_link(node) or child_text(node, ("link", "id", "guid"))
        if not title or not link:
            continue
        guid = child_text(node, ("guid", "id")) or link
        summary = child_text(node, ("description", "summary", "content"))
        published = child_text(node, ("pubdate", "published", "updated"))
        author = child_text(node, ("creator", "author", "name"))
        items.append(
            SignalItem(
                source_id=source_id,
                source_url=source_url,
                item_id=guid,
                title=title,
                url=urllib.parse.urljoin(source_url, link),
                summary=summary,
                published_at=parse_date(published),
                author=author,
                tags=list(source.get("tags", [])),
            )
        )
    return items


def parse_date(value: str) -> str:
    if not value:
        return ""
    try:
        dt = email.utils.parsedate_to_datetime(value)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.astimezone(timezone.utc).replace(microsecond=0).isoformat()
    except Exception:
        return value


def parse_html_links(source: dict[str, Any], text: str) -> list[SignalItem]:
    base_url = source["url"]
    base_parsed = urllib.parse.urlparse(base_url)
    base_path = base_parsed.path.rstrip("/")
    include = source.get("include_url_patterns", [])
    exclude = source.get("exclude_url_patterns", [])
    seen: set[str] = set()
    items: list[SignalItem] = []
    collector = LinkCollector()
    collector.feed(text)
    for href, inner in collector.links:
        if href.strip().startswith("#"):
            continue
        url = urllib.parse.urljoin(base_url, html.unescape(href))
        parsed = urllib.parse.urlparse(url)
        path = parsed.path
        if path.rstrip("/") == base_path:
            continue
        if include and not any(p in path for p in include):
            continue
        if exclude and any(p in path for p in exclude):
            continue
        if url in seen:
            continue
        title = normalize_space(inner)
        if not title:
            title = path.rsplit("/", 1)[-1]
        seen.add(url)
        items.append(
            SignalItem(
                source_id=source["id"],
                source_url=base_url,
                item_id=url,
                title=title,
                url=url,
                tags=list(source.get("tags", [])),
            )
        )
    return items


def parse_snapshot(
    source: dict[str, Any],
    text: str,
    state: dict[str, Any],
) -> tuple[list[SignalItem], dict[str, dict[str, Any]]]:
    source_id = source["id"]
    body = snapshot_text(source, text)
    if not body:
        return [], {}
    digest = hashlib.sha256(body.encode("utf-8")).hexdigest()
    previous = state.get("snapshots", {}).get(source_id, {})
    if previous.get("hash") == digest:
        return [], {}

    title = source.get("title") or source.get("description") or f"{source_id} changed"
    link = source.get("link_url") or source["url"]
    summary = snapshot_summary(previous.get("content", ""), body)
    item = SignalItem(
        source_id=source_id,
        source_url=source["url"],
        item_id=digest[:24],
        title=title,
        url=link,
        summary=summary,
        published_at=now_iso(),
        tags=list(source.get("tags", [])),
    )
    return [item], {
        item.stable_key: {
            "source_id": source_id,
            "hash": digest,
            "content": body,
            "url": link,
            "updated_at": now_iso(),
            "title": title,
        }
    }


def snapshot_text(source: dict[str, Any], text: str) -> str:
    fmt = source.get("snapshot_format", "")
    if not fmt:
        url_path = urllib.parse.urlparse(source.get("url", "")).path.lower()
        fmt = "html" if url_path.endswith((".html", "/")) or "<html" in text[:500].lower() else "text"
    if fmt == "html":
        collector = TextCollector()
        collector.feed(text)
        return collector.text()
    return "\n".join(line.rstrip() for line in text.replace("\r\n", "\n").splitlines()).strip()


def snapshot_summary(previous: str, current: str) -> str:
    if not previous:
        lines = current.splitlines()[:24]
        return "Initial snapshot captured.\n" + "\n".join(lines)
    diff_lines = list(difflib.unified_diff(
        previous.splitlines(),
        current.splitlines(),
        fromfile="previous",
        tofile="current",
        lineterm="",
        n=2,
    ))
    interesting = [
        line for line in diff_lines
        if line.startswith(("+", "-")) and not line.startswith(("+++", "---"))
    ]
    if not interesting:
        interesting = diff_lines
    return "\n".join(interesting[:80])


def apply_snapshot_update(state: dict[str, Any], item: SignalItem, snapshot_updates: dict[str, dict[str, Any]]) -> None:
    update = snapshot_updates.get(item.stable_key)
    if not update:
        return
    state.setdefault("snapshots", {})[update["source_id"]] = {
        "hash": update["hash"],
        "content": update["content"],
        "url": update["url"],
        "title": update["title"],
        "updated_at": update["updated_at"],
    }


def score_item(item: SignalItem, source: dict[str, Any], keyword_weights: dict[str, int]) -> tuple[int, list[str]]:
    score = int(source.get("base_score", 30))
    reasons = [f"base:{score}"]
    haystack = " ".join([
        item.title,
        item.summary,
        item.author,
        " ".join(item.tags or []),
    ]).lower()
    for keyword, weight in keyword_weights.items():
        if keyword_matches(haystack, keyword):
            score += int(weight)
            reasons.append(f"{keyword}+{weight}")
    return score, reasons


def keyword_matches(haystack: str, keyword: str) -> bool:
    needle = keyword.lower()
    if re.fullmatch(r"[a-z0-9][a-z0-9 +#./-]*", needle):
        return re.search(rf"(?<![a-z0-9]){re.escape(needle)}(?![a-z0-9])", haystack) is not None
    return needle in haystack


def route_url(base_url: str, route: str) -> str:
    return base_url.rstrip("/") + "/webhooks/" + route.lstrip("/")


def canonical_url_key(url: str) -> str:
    parsed = urllib.parse.urlparse(url)
    return urllib.parse.urlunparse((
        parsed.scheme.lower(),
        parsed.netloc.lower(),
        parsed.path,
        "",
        parsed.query,
        "",
    ))


def mark_seen_item(state: dict[str, Any], item: SignalItem) -> None:
    state.setdefault("seen", {}).setdefault(item.stable_key, {
        "first_seen_at": now_iso(),
        "source_id": item.source_id,
        "title": item.title,
        "url": item.url,
    })


def mark_seen_candidate(state: dict[str, Any], candidate: dict[str, Any]) -> None:
    state.setdefault("seen", {}).setdefault(candidate["stable_key"], {
        "first_seen_at": now_iso(),
        "source_id": candidate["source_id"],
        "title": candidate["title"],
        "url": candidate["url"],
    })


def post_webhook(url: str, secret: str, payload: dict[str, Any], timeout: int) -> tuple[int, str]:
    body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    sig = "sha256=" + hmac.new(secret.encode("utf-8"), body, hashlib.sha256).hexdigest()
    req = urllib.request.Request(
        url,
        data=body,
        headers={
            "Content-Type": "application/json",
            "X-Hub-Signature-256": sig,
            "X-GitHub-Event": payload.get("event_type", "signal"),
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.status, resp.read().decode("utf-8", errors="replace")


def log_line(path: Path, message: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as f:
        f.write(f"{now_iso()} {message}\n")


def send_alert(settings: dict[str, Any], title: str, body: str, log_path: Path) -> None:
    script_value = os.environ.get("HERMES_ALERT_SCRIPT") or settings.get("alert_script", "~/.hermes/bin/hermes-alert.sh")
    if not script_value:
        return
    script = expand_path(str(script_value))
    if not script.exists():
        return
    try:
        subprocess.run(
            [str(script), title],
            input=body,
            text=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=int(settings.get("alert_timeout_seconds", 10)),
            check=False,
        )
    except Exception as exc:
        log_line(log_path, f"alert failed title={title!r} error={exc}")


def build_payload(route: str, candidates: list[dict[str, Any]]) -> dict[str, Any]:
    return {
        "event_type": "signal.batch" if len(candidates) > 1 else "signal.item",
        "route": route,
        "created_at": now_iso(),
        "candidate_count": len(candidates),
        "signals": candidates,
    }


def enabled_summary_artifacts(route: str, settings: dict[str, Any]) -> bool:
    if not settings.get("summary_artifacts", False):
        return False
    routes = settings.get("summary_artifact_routes", [])
    return not routes or route in routes


def write_summary_artifacts(route: str, candidates: list[dict[str, Any]], settings: dict[str, Any]) -> dict[str, str]:
    if not candidates or not enabled_summary_artifacts(route, settings):
        return {}
    base_dir = expand_path(settings.get("summary_artifact_dir", "~/.hermes/state/ai-latest"))
    key_seed = route + "\n" + "\n".join(c["stable_key"] for c in candidates)
    artifact_id = f"{datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%SZ')}-{safe_slug(route)}-{slug_key(key_seed)}"
    artifact_dir = base_dir / artifact_id
    artifact_dir.mkdir(parents=True, exist_ok=True)

    signals_path = artifact_dir / "signals.json"
    analysis_path = artifact_dir / "analysis.md"
    html_path = artifact_dir / "summary.html"

    signals_path.write_text(json.dumps(candidates, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    analysis_path.write_text(render_summary_markdown(route, candidates), encoding="utf-8")
    html_path.write_text(render_summary_html(route, candidates), encoding="utf-8")

    artifact = {
        "artifact_dir": str(artifact_dir),
        "signals_json": str(signals_path),
        "analysis_md": str(analysis_path),
        "summary_html": str(html_path),
    }
    image_kinds = artifact_image_kinds(candidates)
    if "summary" in image_kinds:
        svg_path = artifact_dir / "summary.svg"
        png_path = artifact_dir / "summary.png"
        svg_path.write_text(render_summary_svg(route, candidates), encoding="utf-8")
        render_summary_png(svg_path, png_path, settings)
        artifact["summary_svg"] = str(svg_path)
        artifact["summary_png"] = str(png_path)
    if "infographic" in image_kinds:
        svg_path = artifact_dir / "infographic.svg"
        png_path = artifact_dir / "infographic.png"
        svg_path.write_text(render_infographic_svg(route, candidates), encoding="utf-8")
        render_summary_png(svg_path, png_path, settings)
        artifact["infographic_svg"] = str(svg_path)
        artifact["infographic_png"] = str(png_path)
    return artifact


def safe_slug(value: str) -> str:
    slug = re.sub(r"[^a-zA-Z0-9._-]+", "-", value).strip("-").lower()
    return slug or "summary"


def render_summary_markdown(route: str, candidates: list[dict[str, Any]]) -> str:
    lines = [
        f"# AI latest summary: {route}",
        "",
        f"Generated: {now_iso()}",
        "",
    ]
    for idx, candidate in enumerate(candidates[:5], 1):
        lines.extend([
            f"## {idx}. {candidate['title']}",
            "",
            f"- Source: `{candidate['source_id']}`",
            f"- Score: {candidate['score']} / threshold {candidate['threshold']}",
            f"- URL: {candidate['url']}",
        ])
        if candidate.get("summary"):
            lines.extend(["", "```diff", candidate["summary"][:1600], "```"])
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def candidate_text(candidate: dict[str, Any]) -> str:
    return " ".join([
        candidate.get("source_id", ""),
        candidate.get("title", ""),
        candidate.get("summary", ""),
        " ".join(str(tag) for tag in candidate.get("tags", [])),
    ]).lower()


def is_new_feature_candidate(candidate: dict[str, Any]) -> bool:
    text = candidate_text(candidate)
    patterns = [
        r"\bnew features?\b",
        r"\badded\b",
        r"\badds\b",
        r"\bcan now\b",
        r"\bintroduced\b",
        r"\blaunched\b",
        r"\bsupport for\b",
        r"新機能",
        r"追加",
    ]
    return any(re.search(pattern, text) for pattern in patterns)


def is_version_candidate(candidate: dict[str, Any]) -> bool:
    text = candidate_text(candidate)
    if re.search(r"\bv?\d+\.\d+(?:\.\d+)?(?:[-.][0-9a-z]+)*\b", text):
        return True
    return any(word in text for word in ["release notes", "releases.atom", "changelog", "リリース"])


def artifact_image_kinds(candidates: list[dict[str, Any]]) -> list[str]:
    kinds: list[str] = []
    if any(is_new_feature_candidate(candidate) for candidate in candidates):
        kinds.append("infographic")
    if any(is_version_candidate(candidate) for candidate in candidates) or not kinds:
        kinds.append("summary")
    return kinds


def provider_label(candidate: dict[str, Any]) -> str:
    source_id = candidate.get("source_id", "")
    tags = {str(tag).lower() for tag in candidate.get("tags", [])}
    if "openai" in tags or source_id.startswith("openai"):
        return "OpenAI"
    if "anthropic" in tags or source_id.startswith("anthropic"):
        return "Anthropic"
    if "google" in tags:
        return "Google"
    if "mistral" in tags:
        return "Mistral"
    if "meta" in tags:
        return "Meta"
    if "huggingface" in tags:
        return "Hugging Face"
    if "langchain" in tags:
        return "LangChain"
    return source_id


def candidate_kind(candidate: dict[str, Any]) -> str:
    text = candidate_text(candidate)
    if is_new_feature_candidate(candidate):
        return "新機能"
    if "api" in text or "model" in text:
        return "API/モデル"
    if "changelog" in text or "release" in text:
        return "リリース差分"
    if "engineering" in text:
        return "技術記事"
    if "research" in text:
        return "研究"
    return "公式更新"


def explain_candidate(candidate: dict[str, Any]) -> str:
    kind = candidate_kind(candidate)
    if kind == "新機能":
        return "使い方やワークフローが増える更新です。手元で試せるコマンド、設定、UIの変化を優先して確認します。"
    if kind == "API/モデル":
        return "モデル名、API仕様、移行期限、料金や制限に関わる可能性があります。実装・運用設定への影響を確認します。"
    if kind == "リリース差分":
        return "新機能、修正、挙動変更が含まれる可能性があります。日常利用や自動化への影響を確認します。"
    if kind == "技術記事":
        return "公式の設計意図や実装背景が読める更新です。エージェント運用改善の材料になります。"
    if kind == "研究":
        return "評価、安全性、能力変化の理解に役立つ一次情報です。プロダクト更新の背景として確認します。"
    return "公式ソースで検知したAI関連の更新です。内容と影響範囲を短時間で確認します。"


def next_action(candidate: dict[str, Any]) -> str:
    kind = candidate_kind(candidate)
    if kind == "新機能":
        return "小さな検証環境で使い勝手と制約を試す"
    if kind == "API/モデル":
        return "利用中モデル、beta header、移行期限を確認する"
    if kind == "リリース差分":
        return "変更点を手元のCLI/API設定と照合する"
    if kind == "技術記事":
        return "運用ルールやプロンプトに反映できる点を拾う"
    if kind == "研究":
        return "評価観点と制約をメモして後続検証に回す"
    return "出典を開いて詳細と日付を確認する"


def render_summary_html(route: str, candidates: list[dict[str, Any]]) -> str:
    cards = []
    for candidate in candidates[:5]:
        summary = html.escape(candidate.get("summary", "")[:800])
        if summary:
            summary = "<pre>" + summary + "</pre>"
        cards.append(f"""
        <article class="card">
          <div class="meta">{html.escape(provider_label(candidate))} · {html.escape(candidate_kind(candidate))} · スコア {candidate['score']}</div>
          <h2>{html.escape(candidate['title'])}</h2>
          <p>{html.escape(explain_candidate(candidate))}</p>
          <p class="next">次に見る: {html.escape(next_action(candidate))}</p>
          <p class="url">{html.escape(candidate['url'])}</p>
          {summary}
        </article>
        """)
    return f"""<!doctype html>
<html lang="ja">
<head>
  <meta charset="utf-8">
  <title>AI最新サマリー</title>
  <style>
    body {{ margin: 0; background: #f6f3ea; color: #202124; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }}
    main {{ width: 1120px; margin: 0 auto; padding: 38px 40px 44px; }}
    header {{ border-bottom: 4px solid #2f6f73; padding-bottom: 18px; margin-bottom: 24px; }}
    h1 {{ font-size: 38px; margin: 0 0 8px; letter-spacing: 0; }}
    .subtitle {{ color: #5f6368; font-size: 17px; }}
    .grid {{ display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 18px; }}
    .card {{ background: white; border: 1px solid #ddd7ca; border-radius: 8px; padding: 20px; min-height: 150px; box-shadow: 0 2px 8px rgba(0,0,0,.05); }}
    .meta {{ color: #2f6f73; font-weight: 700; font-size: 13px; text-transform: uppercase; }}
    h2 {{ font-size: 22px; line-height: 1.25; margin: 8px 0 8px; }}
    p {{ font-size: 14px; line-height: 1.55; margin: 8px 0; }}
    .next {{ color: #7a4d16; font-weight: 700; }}
    .url {{ color: #5f6368; font-size: 13px; overflow-wrap: anywhere; }}
    pre {{ white-space: pre-wrap; max-height: 130px; overflow: hidden; color: #3c4043; background: #f8f9fa; border-radius: 6px; padding: 10px; font-size: 12px; }}
  </style>
</head>
<body>
  <main>
    <header>
      <h1>AI最新アップデート</h1>
      <div class="subtitle">{html.escape(route)} · 重要な一次情報を要点化 · {html.escape(now_iso())}</div>
    </header>
    <section class="grid">
      {''.join(cards)}
    </section>
  </main>
</body>
</html>
"""


def wrap_text(value: str, limit: int) -> list[str]:
    words = normalize_space(value).split(" ")
    lines: list[str] = []
    current = ""
    for word in words:
        if len(word) > limit:
            if current:
                lines.append(current)
                current = ""
            lines.extend(word[i:i + limit] for i in range(0, len(word), limit))
            continue
        if not current:
            current = word
        elif len(current) + 1 + len(word) <= limit:
            current += " " + word
        else:
            lines.append(current)
            current = word
    if current:
        lines.append(current)
    if not lines and value:
        lines = [value[:limit]]
    return lines


def render_svg_text(value: str, x: int, y: int, size: int, color: str, max_lines: int, width_chars: int) -> str:
    tspans = []
    for idx, line in enumerate(wrap_text(value, width_chars)[:max_lines]):
        dy = 0 if idx == 0 else size + 8
        tspans.append(f'<tspan x="{x}" dy="{dy}">{html.escape(line)}</tspan>')
    return f'<text x="{x}" y="{y}" font-size="{size}" fill="{color}">' + "".join(tspans) + "</text>"


def render_summary_svg(route: str, candidates: list[dict[str, Any]]) -> str:
    cards = []
    positions = [(44, 150), (612, 150), (44, 346), (612, 346), (44, 542)]
    for idx, candidate in enumerate(candidates[:5]):
        x, y = positions[idx]
        width = 520
        height = 158 if idx < 4 else 88
        cards.append(f'<rect x="{x}" y="{y}" width="{width}" height="{height}" rx="10" fill="#ffffff" stroke="#ded8ca"/>')
        cards.append(f'<text x="{x + 22}" y="{y + 34}" font-size="16" font-weight="700" fill="#2f6f73">{html.escape(candidate["source_id"])} · スコア {candidate["score"]}</text>')
        cards.append(render_svg_text(candidate["title"], x + 22, y + 70, 25, "#202124", 2, 34))
        cards.append(render_svg_text(candidate["url"], x + 22, y + 130, 13, "#5f6368", 1, 62))
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="675" viewBox="0 0 1200 675">
  <rect width="1200" height="675" fill="#f6f3ea"/>
  <rect x="0" y="0" width="1200" height="12" fill="#2f6f73"/>
  <text x="44" y="74" font-family="-apple-system, BlinkMacSystemFont, Segoe UI, sans-serif" font-size="46" font-weight="800" fill="#202124">AI最新</text>
  <text x="44" y="110" font-family="-apple-system, BlinkMacSystemFont, Segoe UI, sans-serif" font-size="18" fill="#5f6368">{html.escape(route)} · {html.escape(now_iso())}</text>
  <g font-family="-apple-system, BlinkMacSystemFont, Segoe UI, sans-serif">
    {''.join(cards)}
  </g>
</svg>
"""


def render_infographic_svg(route: str, candidates: list[dict[str, Any]]) -> str:
    top_candidates = candidates[:4]
    providers = sorted({provider_label(candidate) for candidate in top_candidates})
    kinds = sorted({candidate_kind(candidate) for candidate in top_candidates})
    stat_cards = []
    stats = [
        ("検知候補", str(len(candidates)), "閾値を超えた更新"),
        ("主要ソース", " / ".join(providers[:3]) or "-", "一次情報を優先"),
        ("分類", " / ".join(kinds[:3]) or "-", "影響範囲の目安"),
    ]
    for idx, (label, value, caption) in enumerate(stats):
        x = 44 + idx * 366
        stat_cards.append(f'<rect x="{x}" y="124" width="334" height="76" rx="10" fill="#ffffff" stroke="#ded8ca"/>')
        stat_cards.append(f'<text x="{x + 18}" y="151" font-size="15" font-weight="800" fill="#2f6f73">{html.escape(label)}</text>')
        stat_cards.append(render_svg_text(value, x + 18, 177, 22, "#202124", 1, 20))
        stat_cards.append(f'<text x="{x + 18}" y="193" font-size="12" fill="#5f6368">{html.escape(caption)}</text>')

    rows = []
    y = 250
    for idx, candidate in enumerate(top_candidates, 1):
        rows.append(f'<circle cx="74" cy="{y + 4}" r="18" fill="#2f6f73"/>')
        rows.append(f'<text x="74" y="{y + 11}" font-size="18" font-weight="800" text-anchor="middle" fill="#ffffff">{idx}</text>')
        rows.append(f'<text x="106" y="{y - 14}" font-size="15" font-weight="800" fill="#2f6f73">{html.escape(provider_label(candidate))} · {html.escape(candidate_kind(candidate))} · スコア {candidate["score"]}</text>')
        rows.append(render_svg_text(candidate["title"], 106, y + 18, 23, "#202124", 2, 34))
        rows.append(render_svg_text(explain_candidate(candidate), 106, y + 78, 15, "#3c4043", 2, 34))
        rows.append(render_svg_text("次に見る: " + next_action(candidate), 106, y + 126, 15, "#7a4d16", 1, 34))
        y += 101

    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="675" viewBox="0 0 1200 675">
  <rect width="1200" height="675" fill="#f6f3ea"/>
  <rect x="0" y="0" width="1200" height="12" fill="#2f6f73"/>
  <text x="44" y="66" font-family="-apple-system, BlinkMacSystemFont, Segoe UI, sans-serif" font-size="43" font-weight="800" fill="#202124">AI最新アップデート</text>
  <text x="44" y="102" font-family="-apple-system, BlinkMacSystemFont, Segoe UI, sans-serif" font-size="17" fill="#5f6368">公式ソースの変化を、何が重要か・次に何を見るかで整理</text>
  <g font-family="-apple-system, BlinkMacSystemFont, Segoe UI, sans-serif">
    {''.join(stat_cards)}
    <text x="44" y="228" font-size="18" font-weight="800" fill="#202124">注目ポイント</text>
    {''.join(rows)}
    <rect x="800" y="246" width="332" height="300" rx="12" fill="#ffffff" stroke="#ded8ca"/>
    <text x="826" y="282" font-size="22" font-weight="800" fill="#202124">読み方</text>
    <text x="826" y="322" font-size="16" fill="#3c4043">1. 新機能は小さく試す</text>
    <text x="826" y="358" font-size="16" fill="#3c4043">2. API/モデル更新は移行期限を見る</text>
    <text x="826" y="394" font-size="16" fill="#3c4043">3. リリース差分は設定と照合する</text>
    <text x="826" y="446" font-size="14" fill="#5f6368">出典URLと差分本文は同じartifactの</text>
    <text x="826" y="470" font-size="14" fill="#5f6368">signals.json / analysis.md に保存</text>
    <text x="826" y="516" font-size="14" font-weight="800" fill="#2f6f73">{html.escape(route)} · {html.escape(now_iso())}</text>
  </g>
</svg>
"""


def render_summary_png(svg_path: Path, png_path: Path, settings: dict[str, Any]) -> None:
    renderer = os.environ.get("HERMES_SUMMARY_PNG_RENDERER") or settings.get("summary_png_renderer", "magick")
    renderer_path = shutil.which(renderer) if renderer else ""
    if renderer_path:
        try:
            subprocess.run(
                [renderer_path, str(svg_path), str(png_path)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=int(settings.get("summary_png_timeout_seconds", 20)),
                check=True,
            )
            return
        except Exception:
            pass
    write_fallback_png(png_path)


def write_fallback_png(path: Path, width: int = 1200, height: int = 675) -> None:
    import struct
    import zlib

    bg = (246, 243, 234)
    accent = (47, 111, 115)
    white = (255, 255, 255)
    rows = []
    for y in range(height):
        row = bytearray([0])
        for x in range(width):
            if y < 12:
                row.extend(accent)
            elif 150 <= y <= 308 and (44 <= x <= 564 or 612 <= x <= 1132):
                row.extend(white)
            elif 346 <= y <= 504 and (44 <= x <= 564 or 612 <= x <= 1132):
                row.extend(white)
            else:
                row.extend(bg)
        rows.append(bytes(row))

    def chunk(kind: bytes, data: bytes) -> bytes:
        crc = zlib.crc32(kind + data) & 0xFFFFFFFF
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", crc)

    raw = b"".join(rows)
    payload = [
        b"\x89PNG\r\n\x1a\n",
        chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)),
        chunk(b"IDAT", zlib.compress(raw, 9)),
        chunk(b"IEND", b""),
    ]
    path.write_bytes(b"".join(payload))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", default="config/signal-watchers.json")
    parser.add_argument("--state")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--allow-first-run-send", action="store_true")
    args = parser.parse_args()

    config_path = expand_path(args.config)
    config = load_json(config_path, None)
    if not isinstance(config, dict) or config.get("version") != 1:
        print(f"invalid watcher config: {config_path}", file=sys.stderr)
        return 2

    settings = config.get("settings", {})
    state_path = expand_path(args.state or settings.get("state_file", "~/.hermes/state/signal-watcher-state.json"))
    log_path = expand_path(settings.get("log_file", "~/.hermes/logs/hermes-signal-watcher.log"))
    env_file_values = load_env_file(expand_path(settings.get("env_file", "~/.hermes/.env")))
    state = load_json(state_path, {"seen": {}, "sent": {}, "runs": []})
    first_run = not state.get("initialized")
    timeout = int(settings.get("source_timeout_seconds", 20))
    user_agent = settings.get("user_agent", "grok-signal-agent/0.1")
    max_items = int(settings.get("max_items_per_source", 20))

    observed: list[SignalItem] = []
    observed_url_keys: set[str] = set()
    candidates: list[dict[str, Any]] = []
    snapshot_updates: dict[str, dict[str, Any]] = {}
    errors: list[str] = []

    for source in config.get("sources", []):
        if not source.get("enabled", True):
            continue
        try:
            text = fetch_text(source["url"], timeout, user_agent)
            if source.get("type") == "feed":
                items = parse_feed(source, text)
            elif source.get("type") == "html_links":
                items = parse_html_links(source, text)
            elif source.get("type") == "snapshot":
                items, source_snapshot_updates = parse_snapshot(source, text, state)
                snapshot_updates.update(source_snapshot_updates)
            else:
                errors.append(f"{source.get('id')}: unsupported type {source.get('type')}")
                continue
        except (urllib.error.URLError, TimeoutError, ET.ParseError, OSError, ValueError) as exc:
            errors.append(f"{source.get('id')}: {exc}")
            continue

        source_max_items = int(source.get("max_items", max_items))
        prime_existing = (
            source.get("prime_existing", False)
            and source.get("id") not in state.get("source_initialized", {})
        )
        for item in items[:source_max_items]:
            url_key = canonical_url_key(item.url)
            if url_key in observed_url_keys:
                continue
            observed_url_keys.add(url_key)
            observed.append(item)
            if prime_existing:
                mark_seen_item(state, item)
                apply_snapshot_update(state, item, snapshot_updates)
                continue
            key = item.stable_key
            if key in state.get("seen", {}):
                continue
            score, reasons = score_item(item, source, config.get("keyword_weights", {}))
            min_score = int(source.get("min_score", settings.get("default_min_score", 70)))
            if score >= min_score:
                candidates.append({
                    "source_id": item.source_id,
                    "source_url": item.source_url,
                    "title": item.title,
                    "url": item.url,
                    "summary": item.summary[:600],
                    "published_at": item.published_at,
                    "author": item.author,
                    "tags": item.tags or [],
                    "score": score,
                    "threshold": min_score,
                    "score_reasons": reasons,
                    "stable_key": key,
                    "route": source.get("route") or settings.get("default_route", "signal-catchup"),
                    "cooldown_minutes": int(source.get("cooldown_minutes", settings.get("default_cooldown_minutes", 90))),
                })
        state.setdefault("source_initialized", {})[source["id"]] = now_iso()

    candidates.sort(key=lambda c: c["score"], reverse=True)
    candidate_keys = {c["stable_key"] for c in candidates}
    should_prime_only = (
        first_run
        and settings.get("prime_only_on_first_run", True)
        and not args.allow_first_run_send
    )
    sent_count = 0

    if should_prime_only:
        for item in observed:
            mark_seen_item(state, item)
            apply_snapshot_update(state, item, snapshot_updates)
        log_line(log_path, f"primed {len(observed)} observed items; no webhook sent")
    else:
        for item in observed:
            if item.stable_key not in candidate_keys:
                mark_seen_item(state, item)
                apply_snapshot_update(state, item, snapshot_updates)

        default_route = settings.get("default_route", "signal-catchup")
        candidates_by_route: dict[str, list[dict[str, Any]]] = {}
        for candidate in candidates:
            candidates_by_route.setdefault(candidate["route"], []).append(candidate)

        default_route_candidates = candidates_by_route.pop(default_route, [])
        batch_min_items = int(settings.get("batch_min_items", 4))
        batch_min_score = int(settings.get("batch_min_score", 220))
        total_score = sum(c["score"] for c in default_route_candidates)
        if default_route_candidates:
            if len(default_route_candidates) >= batch_min_items and total_score >= batch_min_score:
                batch_route = settings.get("batch_route", "tech-digest-trigger")
                sent = send_candidates(batch_route, default_route_candidates, config, settings, env_file_values, args.dry_run, timeout, state, log_path)
            else:
                sent = send_candidates(default_route, default_route_candidates, config, settings, env_file_values, args.dry_run, timeout, state, log_path)
            sent_count += sent
            if sent:
                for candidate in default_route_candidates:
                    mark_seen_candidate(state, candidate)
                    update_item = next((item for item in observed if item.stable_key == candidate["stable_key"]), None)
                    if update_item:
                        apply_snapshot_update(state, update_item, snapshot_updates)

        for route, route_candidates in candidates_by_route.items():
            sent = send_candidates(route, route_candidates, config, settings, env_file_values, args.dry_run, timeout, state, log_path)
            sent_count += sent
            if sent:
                for candidate in route_candidates:
                    mark_seen_candidate(state, candidate)
                    update_item = next((item for item in observed if item.stable_key == candidate["stable_key"]), None)
                    if update_item:
                        apply_snapshot_update(state, update_item, snapshot_updates)

    if errors and not observed:
        send_alert(
            settings,
            "Hermes signal watcher source failures",
            "\n".join(errors[:10]),
            log_path,
        )

    state["initialized"] = True
    state.setdefault("runs", []).append({
        "at": now_iso(),
        "observed": len(observed),
        "candidates": len(candidates),
        "sent": sent_count,
        "errors": errors,
        "dry_run": args.dry_run,
    })
    state["runs"] = state["runs"][-50:]
    if not args.dry_run:
        save_json(state_path, state)

    print(json.dumps({
        "observed": len(observed),
        "candidates": len(candidates),
        "sent": sent_count,
        "errors": errors,
        "dry_run": args.dry_run,
        "prime_only": should_prime_only,
    }, ensure_ascii=False))
    return 0 if observed or not errors else 1


def send_candidates(
    route: str,
    candidates: list[dict[str, Any]],
    config: dict[str, Any],
    settings: dict[str, Any],
    env_file_values: dict[str, str],
    dry_run: bool,
    timeout: int,
    state: dict[str, Any],
    log_path: Path,
) -> int:
    base_url = env_value(settings.get("webhook_base_url_env", ""), env_file_values) or settings.get("default_webhook_base_url", "http://127.0.0.1:8644")
    secret_env = settings.get("post_trigger_secret_env") if route != settings.get("default_route", "signal-catchup") else settings.get("secret_env")
    secret = env_value(secret_env or "", env_file_values)
    payload = build_payload(route, candidates)
    url = route_url(base_url, route)
    cooldown_minutes = max(int(c.get("cooldown_minutes", settings.get("default_cooldown_minutes", 90))) for c in candidates)
    last_sent = state.setdefault("last_sent_routes", {}).get(route, 0)
    now_ts = time.time()
    if last_sent and now_ts - float(last_sent) < cooldown_minutes * 60:
        log_line(log_path, f"cooldown route={route} candidates={len(candidates)} minutes={cooldown_minutes}")
        return 0
    artifact = write_summary_artifacts(route, candidates, settings)
    if artifact:
        payload["artifact"] = artifact
        log_line(log_path, f"summary artifacts route={route} dir={artifact['artifact_dir']}")
    if dry_run:
        log_line(log_path, f"dry-run route={route} candidates={len(candidates)}")
        return 0
    if not secret:
        log_line(log_path, f"missing secret env for route={route} env={secret_env}")
        send_alert(
            settings,
            "Hermes signal watcher missing webhook secret",
            f"route={route}\nenv={secret_env}\ncandidates={len(candidates)}",
            log_path,
        )
        return 0
    try:
        status, body = post_webhook(url, secret, payload, timeout)
        for candidate in candidates:
            state.setdefault("sent", {})[candidate["stable_key"]] = {
                "sent_at": now_iso(),
                "route": route,
                "status": status,
            }
        state.setdefault("last_sent_routes", {})[route] = now_ts
        log_line(log_path, f"sent route={route} candidates={len(candidates)} status={status} body={body[:200]}")
        return len(candidates)
    except Exception as exc:
        log_line(log_path, f"send failed route={route} candidates={len(candidates)} error={exc}")
        send_alert(
            settings,
            "Hermes signal watcher webhook send failed",
            f"route={route}\ncandidates={len(candidates)}\nerror={exc}",
            log_path,
        )
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
