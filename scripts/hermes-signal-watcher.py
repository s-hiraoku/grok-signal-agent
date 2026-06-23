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


def build_payload(
    route: str,
    candidates: list[dict[str, Any]],
    group_slug: str | None = None,
    group_label: str | None = None,
) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "event_type": "signal.batch" if len(candidates) > 1 else "signal.item",
        "route": route,
        "created_at": now_iso(),
        "candidate_count": len(candidates),
        "signals": public_candidates(candidates),
    }
    if group_slug and group_label:
        payload["group"] = {
            "type": "provider",
            "slug": group_slug,
            "label": group_label,
        }
    return payload


def public_candidates(candidates: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        {key: value for key, value in candidate.items() if key != "summary_full"}
        for candidate in candidates
    ]


def enabled_summary_artifacts(route: str, settings: dict[str, Any]) -> bool:
    if not settings.get("summary_artifacts", False):
        return False
    routes = settings.get("summary_artifact_routes", [])
    return not routes or route in routes


def write_summary_artifacts(
    route: str,
    candidates: list[dict[str, Any]],
    settings: dict[str, Any],
    group_slug: str | None = None,
    group_label: str | None = None,
) -> dict[str, str]:
    if not candidates or not enabled_summary_artifacts(route, settings):
        return {}
    base_dir = expand_path(settings.get("summary_artifact_dir", "~/.hermes/state/ai-latest"))
    display_route = route if not group_label else f"{route} / {group_label}"
    route_slug = safe_slug(route if not group_slug else f"{route}-{group_slug}")
    key_seed = route + "\n" + (group_slug or "") + "\n" + "\n".join(c["stable_key"] for c in candidates)
    artifact_id = f"{datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%SZ')}-{route_slug}-{slug_key(key_seed)}"
    artifact_dir = base_dir / artifact_id
    artifact_dir.mkdir(parents=True, exist_ok=True)

    signals_path = artifact_dir / "signals.json"
    analysis_path = artifact_dir / "analysis.md"
    html_path = artifact_dir / "summary.html"
    index_path = artifact_dir / "index.html"

    signals_path.write_text(json.dumps(public_candidates(candidates), ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    analysis_path.write_text(render_summary_markdown(display_route, candidates), encoding="utf-8")
    html = render_summary_html(display_route, candidates)
    html_path.write_text(html, encoding="utf-8")
    index_path.write_text(html, encoding="utf-8")

    artifact = {
        "artifact_dir": str(artifact_dir),
        "signals_json": str(signals_path),
        "analysis_md": str(analysis_path),
        "summary_html": str(html_path),
        "index_html": str(index_path),
    }
    if group_slug and group_label:
        artifact["group_type"] = "provider"
        artifact["group_slug"] = group_slug
        artifact["group_label"] = group_label
    feature_facts = infographic_feature_facts(candidates, settings)
    if feature_facts:
        facts_path = artifact_dir / "facts.json"
        factcheck_path = artifact_dir / "factcheck.md"
        facts_path.write_text(json.dumps(feature_facts, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        factcheck_path.write_text(render_factcheck_markdown(display_route, feature_facts), encoding="utf-8")
        artifact["facts_json"] = str(facts_path)
        artifact["factcheck_md"] = str(factcheck_path)
        infographics = []
        for idx, fact in enumerate(feature_facts, 1):
            infographic_html_path = artifact_dir / f"infographic-{idx:02d}.html"
            png_path = artifact_dir / f"infographic-{idx:02d}.png"
            infographic_html_path.write_text(render_infographic_html(display_route, fact), encoding="utf-8")
            render_infographic_png(infographic_html_path, png_path, settings)
            infographics.append({
                "index": idx,
                "feature": fact["feature"],
                "source_id": fact["source_id"],
                "fact_status": fact["status"],
                "html": str(infographic_html_path),
                "png": str(png_path),
            })
            if idx == 1:
                alias_html = artifact_dir / "infographic.html"
                alias_png = artifact_dir / "infographic.png"
                shutil.copyfile(infographic_html_path, alias_html)
                shutil.copyfile(png_path, alias_png)
                artifact["infographic_html"] = str(alias_html)
                artifact["infographic_png"] = str(alias_png)
        artifact["infographics"] = infographics
    archive_dir = archive_artifact(artifact_dir, artifact_id, settings, group_slug, group_label)
    if archive_dir:
        artifact["archive_dir"] = str(archive_dir)
    latest_dir = publish_latest_artifact(artifact_dir, settings, group_slug)
    if latest_dir:
        artifact["latest_dir"] = str(latest_dir)
        artifact["latest_index_html"] = str(latest_dir / "index.html")
    return artifact


def archive_artifact(
    artifact_dir: Path,
    artifact_id: str,
    settings: dict[str, Any],
    group_slug: str | None = None,
    group_label: str | None = None,
) -> Path | None:
    archive_root_value = settings.get("summary_archive_dir", "~/.hermes/archive/ai-latest")
    if not archive_root_value:
        return None
    archive_root = expand_path(str(archive_root_value))
    run_date = artifact_id[:8]
    year = run_date[:4] if len(run_date) >= 4 else "unknown"
    month = run_date[4:6] if len(run_date) >= 6 else "unknown"
    target = archive_root / year / month / artifact_id
    if target.exists():
        shutil.rmtree(target)
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(artifact_dir, target)
    append_archive_index(archive_root, artifact_id, target, group_slug, group_label)
    return target


def append_archive_index(
    archive_root: Path,
    artifact_id: str,
    target: Path,
    group_slug: str | None = None,
    group_label: str | None = None,
) -> None:
    index_path = archive_root / "index.jsonl"
    record = {
        "run_id": artifact_id,
        "created_at": now_iso(),
        "local_path": str(target),
    }
    if group_slug and group_label:
        record["group_type"] = "provider"
        record["group_slug"] = group_slug
        record["group_label"] = group_label
    index_path.parent.mkdir(parents=True, exist_ok=True)
    with index_path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")


def publish_latest_artifact(artifact_dir: Path, settings: dict[str, Any], group_slug: str | None = None) -> Path | None:
    latest_dir_value = settings.get("summary_latest_dir", "~/.hermes/public/ai-latest/latest")
    if not latest_dir_value:
        return None
    latest_root = expand_path(str(latest_dir_value))
    latest_dir = latest_root
    if group_slug:
        cleanup_ungrouped_latest_files(latest_root)
        latest_dir = latest_dir / group_slug
    tmp_dir = latest_dir.with_name(latest_dir.name + ".tmp")
    if tmp_dir.exists():
        shutil.rmtree(tmp_dir)
    tmp_dir.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(artifact_dir, tmp_dir)
    if latest_dir.exists():
        shutil.rmtree(latest_dir)
    tmp_dir.replace(latest_dir)
    return latest_dir


def cleanup_ungrouped_latest_files(latest_root: Path) -> None:
    if not latest_root.exists():
        return
    for name in [
        "signals.json",
        "analysis.md",
        "summary.html",
        "index.html",
        "infographic.html",
        "infographic.svg",
        "infographic.png",
        "summary.svg",
        "summary.png",
    ]:
        path = latest_root / name
        if path.exists() and path.is_file():
            path.unlink()


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
        summary = candidate_summary(candidate)
        if summary:
            lines.extend(["", "```diff", summary[:1600], "```"])
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def candidate_text(candidate: dict[str, Any]) -> str:
    return " ".join([
        candidate.get("source_id", ""),
        candidate.get("title", ""),
        candidate_summary(candidate),
        " ".join(str(tag) for tag in candidate.get("tags", [])),
    ]).lower()


def candidate_summary(candidate: dict[str, Any]) -> str:
    return str(candidate.get("summary_full") or candidate.get("summary") or "")


def is_new_feature_candidate(candidate: dict[str, Any]) -> bool:
    text = candidate_text(candidate)
    patterns = [
        r"\bnew features?\b",
        r"\badd\b",
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


def infographic_feature_items(candidates: list[dict[str, Any]]) -> list[tuple[dict[str, Any], str]]:
    items: list[tuple[dict[str, Any], str]] = []
    seen: set[str] = set()
    for candidate in candidates:
        for feature in candidate_feature_lines(candidate):
            key = normalize_space(feature).lower()
            if key in seen:
                continue
            seen.add(key)
            items.append((candidate, feature))
    return items


def candidate_feature_lines(candidate: dict[str, Any]) -> list[str]:
    features: list[str] = []
    for raw_line in candidate_summary(candidate).splitlines():
        line = raw_line.strip()
        if not line.startswith("+") or line.startswith("+++"):
            continue
        feature = clean_feature_line(line)
        if feature and is_feature_statement(feature, candidate):
            features.append(feature)
    if not features:
        summary = candidate_summary(candidate)
        summary_text = snapshot_text({"snapshot_format": "html" if looks_like_html(summary) else "text"}, summary)
        for raw_line in summary_text.splitlines():
            feature = clean_feature_line(raw_line)
            if feature and is_feature_statement(feature, candidate):
                features.append(feature)
    if not features:
        title = normalize_space(candidate.get("title", ""))
        if title and is_feature_statement(title, candidate):
            features.append(title)
    return features


def clean_feature_line(line: str) -> str:
    cleaned = html.unescape(normalize_space(line.lstrip("+").strip()))
    cleaned = re.sub(r"<[^>]+>", " ", cleaned)
    cleaned = normalize_space(cleaned)
    cleaned = re.sub(r"^[-*#\s]+", "", cleaned).strip()
    cleaned = re.sub(r"^\d+[.)]\s*", "", cleaned).strip()
    cleaned = re.sub(r"\s*\(#[0-9].*$", "", cleaned).strip()
    cleaned = cleaned.rstrip(" ,.;")
    return cleaned[:220]


def is_feature_statement(value: str, candidate: dict[str, Any]) -> bool:
    lowered = value.lower().strip(" :-")
    if lowered in {
        "new feature",
        "new features",
        "features",
        "improvements",
        "improvements and bug fixes",
        "bug fixes",
        "performance improvements and bug fixes",
    }:
        return False
    if len(value) < 12:
        return False
    if re.fullmatch(r"v?\d+\.\d+(?:\.\d+)?(?:[-.][0-9a-z]+)*", lowered):
        return False
    return is_new_feature_candidate({"title": value, "summary": value, "tags": candidate.get("tags", [])})


def should_write_infographic(candidates: list[dict[str, Any]]) -> bool:
    return bool(infographic_feature_items(candidates))


def infographic_feature_facts(candidates: list[dict[str, Any]], settings: dict[str, Any]) -> list[dict[str, Any]]:
    facts = []
    max_items = int(settings.get("summary_max_infographics", 8))
    for idx, (candidate, feature) in enumerate(infographic_feature_items(candidates)[:max_items], 1):
        facts.append(build_feature_fact(candidate, feature, idx, settings))
    return facts


def build_feature_fact(candidate: dict[str, Any], feature: str, index: int, settings: dict[str, Any]) -> dict[str, Any]:
    source_url = candidate.get("url") or candidate.get("source_url", "")
    evidence_lines = feature_evidence_from_summary(candidate, feature)
    status = "summary-confirmed" if evidence_lines else "candidate-only"
    fetched_url = ""
    fetch_error = ""
    source_title = candidate.get("title", "")
    for url in unique_urls([candidate.get("url", ""), candidate.get("source_url", "")]):
        try:
            timeout = int(settings.get("source_timeout_seconds", 20))
            user_agent = settings.get("user_agent", "grok-signal-agent/0.1")
            fetched = fetch_text(url, timeout, user_agent)
            fetched_url = url
            source_text = snapshot_text({"snapshot_format": "html" if looks_like_html(fetched) else "text"}, fetched)
            source_evidence = feature_evidence_from_text(source_text, feature)
            if source_evidence:
                evidence_lines = source_evidence
                status = "official-source-confirmed"
                break
        except Exception as exc:
            fetch_error = str(exc)

    return {
        "index": index,
        "feature": feature,
        "title": feature_title(candidate, feature),
        "source_id": candidate["source_id"],
        "source_url": source_url,
        "fetched_url": fetched_url,
        "source_title": source_title,
        "provider": provider_label(candidate),
        "kind": candidate_kind(candidate),
        "score": candidate["score"],
        "status": status,
        "fetch_error": fetch_error,
        "evidence": evidence_lines[:4],
        "what_it_is": describe_feature(candidate, feature),
        "detail": feature_detail(candidate, feature),
        "use_case": feature_use_case(candidate, feature),
        "check_first": feature_check_first(candidate, feature),
    }


def unique_urls(values: list[str]) -> list[str]:
    urls = []
    seen = set()
    for value in values:
        if not value or value in seen:
            continue
        seen.add(value)
        urls.append(value)
    return urls


def feature_title(candidate: dict[str, Any], feature: str) -> str:
    text = feature_context(candidate, feature)
    if "usage" in text and ("credit" in text or "limit" in text):
        return "/usageで利用上限リセットクレジットを確認・利用"
    if "claude mcp login" in text or "claude mcp logout" in text:
        return "MCPサーバー認証をCLIから実行"
    if "status filtering" in text and "workflows" in text:
        return "/workflowsでステータス絞り込み"
    if "skills" in text and "/plugin" in text:
        return "/pluginにSkillsセクションを追加"
    if "teammatemode" in text and "iterm2" in text:
        return "iTerm2向けteammateMode設定を追加"
    if "refresh credentials" in text and "aws" in text:
        return "AWS認証情報を/logから更新"
    if "record" in text and "replay" in text:
        return "Record & Replayで操作手順をスキル化"
    if "bulk action" in text or "bulk actions" in text:
        return "自動化履歴を一括操作"
    if "handoff" in text:
        return "スレッドを別ホストへ引き継ぎ"
    title = re.sub(r"^(added|adds|add|introduced|launched)\s+", "", feature, flags=re.IGNORECASE).strip()
    title = re.sub(r"\s+", " ", title)
    return title[:72].rstrip(" ,.;")


def looks_like_html(value: str) -> bool:
    return bool(re.search(r"<(?:html|body|h[1-6]|li|ul|ol|p|div|article|main)\b", value[:2000].lower()))


def feature_context(candidate: dict[str, Any], feature: str) -> str:
    tags = " ".join(str(tag) for tag in candidate.get("tags", []))
    return f"{feature} {candidate.get('source_id', '')} {tags}".lower()


def feature_evidence_from_summary(candidate: dict[str, Any], feature: str) -> list[str]:
    evidence = []
    feature_key = normalize_for_match(feature)
    for raw_line in candidate_summary(candidate).splitlines():
        cleaned = clean_feature_line(raw_line)
        if cleaned and (normalize_for_match(cleaned) == feature_key or match_feature_phrase(cleaned, feature)):
            evidence.append(cleaned)
    return evidence


def feature_evidence_from_text(text: str, feature: str) -> list[str]:
    evidence = []
    for raw_line in text.splitlines():
        line = normalize_space(raw_line)
        if not line:
            continue
        if match_feature_phrase(line, feature):
            evidence.append(line[:240])
        if len(evidence) >= 4:
            break
    if not evidence and match_feature_phrase(normalize_space(text), feature):
        evidence.append(feature)
    return evidence


def normalize_for_match(value: str) -> str:
    return re.sub(r"[^a-z0-9ぁ-んァ-ヶ一-龠]+", " ", value.lower()).strip()


def match_feature_phrase(haystack: str, feature: str) -> bool:
    haystack_norm = normalize_for_match(haystack)
    feature_norm = normalize_for_match(feature)
    if not feature_norm:
        return False
    if feature_norm in haystack_norm:
        return True
    words = [word for word in feature_norm.split() if len(word) >= 4]
    if not words:
        return False
    matches = sum(1 for word in words[:10] if word in haystack_norm)
    return matches >= min(4, max(2, len(words[:10]) // 2))


def describe_feature(candidate: dict[str, Any], feature: str) -> str:
    text = feature_context(candidate, feature)
    if "record" in text and "replay" in text:
        return "操作した手順を記録し、あとから再利用できるワークフローとして扱う機能です。"
    if "status filtering" in text and "workflows" in text:
        return "/workflows の詳細画面で、表示項目をステータス別に絞り込む機能です。"
    if "skills" in text and "/plugin" in text:
        return "/plugin の Installed タブで、インストール済みプラグインが持つ Skills を見られる機能です。"
    if "teammatemode" in text and "iterm2" in text:
        return "teammateMode で iTerm2 を明示し、必要な CLI が見つからない時は警告する設定です。"
    if "refresh credentials" in text and "aws" in text:
        return "/log から Claude Platform on AWS の認証情報を更新できる操作です。"
    if "mcp" in text:
        return "外部ツールやデータソースとの接続・管理を広げるための機能です。"
    if "browser" in text or "chrome" in text:
        return "ブラウザ上の作業や確認をエージェントの流れに組み込むための機能です。"
    if "automation run history" in text and "bulk action" in text:
        return "自動化の実行履歴に対して、既読化やアーカイブ対象の整理をまとめて行う機能です。"
    if "automation" in text or "bulk action" in text:
        return "繰り返し実行や履歴管理をまとめて扱いやすくする運用向けの機能です。"
    if "usage" in text and ("credit" in text or "limit" in text):
        return "利用上限やリセットクレジットの状態確認・利用をコマンド内で扱う機能です。"
    if "handoff" in text:
        return "作業中のスレッドや状態を別の環境へ引き継ぎやすくする機能です。"
    if "api" in text or "model" in text:
        return "APIやモデル利用時の選択肢、指定方法、運用条件を広げる機能です。"
    return "公式リリースで追加された新しい使い方です。既存の作業に組み込めるかを確認します。"


def feature_detail(candidate: dict[str, Any], feature: str) -> str:
    text = feature_context(candidate, feature)
    if "record" in text and "replay" in text:
        return "一度行った操作を記録し、同じ流れをあとから呼び出せる形にします。画面操作、確認手順、検証の流れなど、毎回同じことを繰り返す作業を再利用しやすくします。"
    if "status filtering" in text and "workflows" in text:
        return "/workflows の一覧が増えた時に、状態ごとに表示を絞れます。失敗した実行だけを見る、待機中のものだけ追う、完了済みを一度隠す、といった確認がしやすくなります。"
    if "skills" in text and "/plugin" in text:
        return "インストール済みプラグインの中に含まれる Skills を /plugin から確認できます。プラグインを入れた後に、どの能力が追加されたのかを探す入口として使えます。"
    if "teammatemode" in text and "iterm2" in text:
        return "teammateMode の起動先として iTerm2 を明示できます。必要な it2 CLI がない場合は警告されるため、意図しないターミナルで起動する前に設定を見直せます。"
    if "refresh credentials" in text and "aws" in text:
        return "/log を見ている最中に AWS 認証の更新操作へ進めます。Claude Platform on AWS の作業中に認証切れが起きた時、ログ確認から復旧までの移動を短くできます。"
    if "mcp" in text:
        return "MCP サーバーとの接続や認証を、作業中の流れから扱いやすくする更新です。GitHub、DB、社内APIなど、外部の情報源をエージェント作業へつなぐ場面で確認します。"
    if "browser" in text or "chrome" in text:
        return "ブラウザでしか確認できない画面や、ログイン済みの管理画面を作業手順に含めやすくする更新です。UI確認、再現調査、管理画面操作の入口になります。"
    if "automation run history" in text and "bulk action" in text:
        return "自動化の実行履歴に対して、複数件をまとめて処理できます。確認済みの履歴を既読化したり、アーカイブ対象を整理したりする時に使います。"
    if "automation" in text or "bulk action" in text:
        return "繰り返し実行される処理や、その実行結果をまとめて扱うための更新です。履歴確認、整理、再実行前の状態確認を短くできます。"
    if "usage" in text and ("credit" in text or "limit" in text):
        return "利用状況や上限に関する情報を、作業中に確認しやすくする更新です。残量を見て作業を続けるか、リセットやプラン条件を確認するかを判断できます。"
    if "handoff" in text:
        return "作業中の状態を別の環境へ移すための更新です。ローカルからリモート、または別ホストへ作業を移したい時に、引き継ぎ先で続きを始めやすくします。"
    if "api" in text or "model" in text:
        return "APIやモデル利用時の指定方法、選択肢、運用条件が増える更新です。検証環境で挙動を比べたり、既存実装の設定値を見直したりする時に確認します。"
    return f"{feature} について、公式リリースで追加された新しい使い方を確認します。まず小さく試し、既存の作業に入れる場所と利用条件を見ます。"


def feature_use_case(candidate: dict[str, Any], feature: str) -> str:
    text = feature_context(candidate, feature)
    if "record" in text and "replay" in text:
        return "定型操作、検証手順、社内ツールの反復作業をスキル化したい場面で使えます。"
    if "status filtering" in text and "workflows" in text:
        return "実行が増えた時に、失敗・待機・完了などを切り分けて確認できます。"
    if "skills" in text and "/plugin" in text:
        return "入れたプラグインで何ができるかを確認し、使う Skills を探す場面で使えます。"
    if "teammatemode" in text and "iterm2" in text:
        return "iTerm2 を前提に teammate 作業を動かしたい環境で、起動先を安定させるために使えます。"
    if "refresh credentials" in text and "aws" in text:
        return "AWS 上の Claude Platform 認証が切れた時に、作業中のログ画面から復旧する場面で使えます。"
    if "mcp" in text:
        return "GitHub、DB、社内API、ドキュメントなどをエージェント作業に接続したい場面で使えます。"
    if "browser" in text or "chrome" in text:
        return "ログイン済み画面の確認、管理画面操作、UIの再現確認が必要な場面で使えます。"
    if "automation run history" in text and "bulk action" in text:
        return "大量の自動化実行結果を読み終えた後、履歴をまとめて片付けたい場面で使えます。"
    if "automation" in text or "bulk action" in text:
        return "複数の実行履歴や定期処理をまとめて整理したい場面で使えます。"
    if "usage" in text and ("credit" in text or "limit" in text):
        return "上限に近い作業中に、残量やリセット可否を確認して作業継続を判断する場面で使えます。"
    if "handoff" in text:
        return "ローカルとリモート、または別ホストへ作業を移す場面で使えます。"
    if "api" in text or "model" in text:
        return "プロダクトのモデル更新、API移行、検証環境での比較テストに使えます。"
    return "日々の開発、検証、ドキュメント更新の中で作業を短くできるか試せます。"


def feature_check_first(candidate: dict[str, Any], feature: str) -> str:
    text = feature_context(candidate, feature)
    if "beta" in text or "header" in text:
        return "有効化ヘッダー、対象モデル、利用可能な組織・地域を確認します。"
    if "record" in text or "computer use" in text:
        return "利用可能地域、権限設定、記録してよい操作範囲を確認します。"
    if "status filtering" in text and "workflows" in text:
        return "対象画面、ショートカットキー、絞り込み後に見えるステータス種別を確認します。"
    if "skills" in text and "/plugin" in text:
        return "Installed タブで表示される Skills 名と、実際に呼べる機能の対応を確認します。"
    if "teammatemode" in text and "iterm2" in text:
        return "iTerm2 と it2 CLI の有無、設定値、auto mode の警告表示を確認します。"
    if "refresh credentials" in text and "aws" in text:
        return "AWS プロファイル、権限、更新後に作業が再開できるかを確認します。"
    if "mcp" in text:
        return "接続先の権限、読み書き範囲、失敗時の戻し方を確認します。"
    if "api" in text or "model" in text:
        return "対象モデル名、料金、rate limit、移行期限を確認します。"
    if "usage" in text and ("credit" in text or "limit" in text):
        return "対象プラン、利用可能なクレジット、実行前の確認表示を見ます。"
    if "automation run history" in text and "bulk action" in text:
        return "既読化とアーカイブの対象条件、戻せる操作かどうかを確認します。"
    return "対象環境、利用条件、既存ワークフローに入れる位置を確認します。"


def render_factcheck_markdown(route: str, facts: list[dict[str, Any]]) -> str:
    lines = [f"# AI latest fact check: {route}", "", f"Generated: {now_iso()}", ""]
    for fact in facts:
        lines.extend([
            f"## {fact['index']}. {fact['feature']}",
            "",
            f"- Provider: {fact['provider']}",
            f"- Source: `{fact['source_id']}`",
            f"- URL: {fact['source_url']}",
            f"- Status: `{fact['status']}`",
        ])
        if fact.get("fetch_error"):
            lines.append(f"- Fetch error: `{fact['fetch_error']}`")
        if fact.get("evidence"):
            lines.extend(["", "Evidence:"])
            for evidence in fact["evidence"]:
                lines.append(f"- {evidence}")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def provider_split_enabled(route: str, settings: dict[str, Any]) -> bool:
    routes = settings.get("provider_split_routes", [])
    return isinstance(routes, list) and route in routes


def split_candidates_for_route(
    route: str,
    candidates: list[dict[str, Any]],
    settings: dict[str, Any],
) -> list[tuple[str | None, str | None, list[dict[str, Any]]]]:
    if not provider_split_enabled(route, settings):
        return [(None, None, candidates)]
    grouped: dict[str, dict[str, Any]] = {}
    for candidate in candidates:
        label = provider_label(candidate)
        slug = safe_slug(label)
        grouped.setdefault(slug, {"label": label, "candidates": []})["candidates"].append(candidate)
    return [
        (slug, str(group["label"]), group["candidates"])
        for slug, group in sorted(grouped.items(), key=lambda item: item[0])
    ]


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
        summary = html.escape(candidate_summary(candidate)[:800])
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
      <div class="subtitle">{html.escape(route)} · 公式情報を要点化 · {html.escape(now_iso())}</div>
    </header>
    <section class="grid">
      {''.join(cards)}
    </section>
  </main>
</body>
</html>
"""


def feature_visual_plan(fact: dict[str, Any]) -> dict[str, Any]:
    text = feature_context({"source_id": fact.get("source_id", ""), "tags": []}, str(fact.get("feature", "")))
    plan: dict[str, Any] = {
        "accent": "#2563eb",
        "steps": [
            ("入口", "対象画面を開く", "どこから使うかを確認"),
            ("操作", "小さく試す", "CLI/API/UIで再現"),
            ("結果", "運用に入れる", "使う場面を決める"),
        ],
    }
    if "claude mcp login" in text or "claude mcp logout" in text:
        plan.update({
            "accent": "#1d4ed8",
            "steps": [
                ("入口", "SSH・CIで作業中", "ブラウザを開きにくい環境"),
                ("操作", "claude mcp login", "/mcpメニューを開かず認証"),
                ("結果", "MCP接続を使える", "外部ツールにすぐ接続"),
            ],
        })
    elif "status filtering" in text and "workflows" in text:
        plan.update({
            "accent": "#0f766e",
            "steps": [
                ("入口", "/workflows詳細", "エージェント実行が増えた画面"),
                ("操作", "fで絞り込み", "状態ごとに表示を切り替え"),
                ("結果", "詰まりを探す", "失敗・待機・完了を分けて確認"),
            ],
        })
    elif "skills" in text and "/plugin" in text:
        plan.update({
            "accent": "#7c3aed",
            "steps": [
                ("入口", "/plugin Installed", "入っているプラグインを見る"),
                ("操作", "Skills欄を確認", "プラグインが持つ能力を一覧化"),
                ("結果", "使うSkillを選ぶ", "呼び出す機能を迷わず探せる"),
            ],
        })
    elif "teammatemode" in text and "iterm2" in text:
        plan.update({
            "accent": "#0891b2",
            "steps": [
                ("入口", "teammate作業", "ターミナル連携を使う"),
                ("操作", "iterm2を指定", "teammateModeで起動先を固定"),
                ("結果", "警告で気づける", "it2 CLI不足を見落としにくい"),
            ],
        })
    elif "refresh credentials" in text and "aws" in text:
        plan.update({
            "accent": "#d97706",
            "steps": [
                ("入口", "/logを開く", "認証切れに気づく"),
                ("操作", "refresh credentials", "AWS認証情報を更新"),
                ("結果", "作業に戻る", "Claude Platform on AWSを継続"),
            ],
        })
    elif "record" in text and "replay" in text:
        plan.update({
            "accent": "#16a34a",
            "steps": [
                ("入口", "手順を実行", "いつもの操作を一度行う"),
                ("操作", "Record & Replay", "操作を再利用できる形にする"),
                ("結果", "Skill化", "反復作業を呼び出せる"),
            ],
        })
    elif "bulk action" in text or "bulk actions" in text:
        plan.update({
            "accent": "#ea580c",
            "steps": [
                ("入口", "実行履歴を見る", "自動化の結果がたまる"),
                ("操作", "まとめて選ぶ", "既読化・整理を一括実行"),
                ("結果", "履歴を片付ける", "次に見るべき実行だけ残す"),
            ],
        })
    return plan


def render_infographic_html(route: str, fact: dict[str, Any]) -> str:
    feature = str(fact["feature"])
    card_title = str(fact.get("title") or feature)
    plan = feature_visual_plan(fact)
    accent = str(plan["accent"])
    what_it_is = str(fact["what_it_is"])
    detail = str(fact["detail"])
    use_case = str(fact["use_case"])
    check_first = str(fact["check_first"])
    steps = list(plan["steps"])
    entry = str(steps[0][1]) if steps else "対象の画面やコマンドを開く"
    action = str(steps[1][1]) if len(steps) > 1 else "小さく試す"
    result = str(steps[2][1]) if len(steps) > 2 else "使える場面を決める"
    provider = str(fact.get("provider") or "")
    kind = str(fact.get("kind") or "新機能")
    return f"""<!doctype html>
<html lang="ja">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=1200, initial-scale=1">
  <title>{html.escape(card_title)}</title>
  <style>
    * {{ box-sizing: border-box; }}
    html, body {{ margin: 0; width: 1200px; height: 675px; overflow: hidden; }}
    body {{
      background: #eef0ec;
      color: #151a23;
      font-family: -apple-system, BlinkMacSystemFont, "Hiragino Sans", "Yu Gothic", "Segoe UI", sans-serif;
      letter-spacing: 0;
    }}
    .page {{ width: 1200px; height: 675px; padding: 34px; }}
    .card {{
      width: 1132px; height: 607px; background: #fffdf8; border: 2px solid #242a32;
      border-radius: 20px; box-shadow: 0 18px 44px rgba(22, 27, 34, .16);
      display: grid; grid-template-columns: 26px 1fr; overflow: hidden;
    }}
    .rail {{ background: {accent}; }}
    .content {{ padding: 30px 38px 28px; min-width: 0; }}
    .meta {{ display: flex; align-items: center; gap: 10px; color: #53606d; font-size: 16px; font-weight: 700; }}
    .dot {{ width: 10px; height: 10px; border-radius: 999px; background: {accent}; }}
    h1 {{
      margin: 14px 0 20px; max-width: 1010px; font-size: 42px; line-height: 1.14; font-weight: 800;
      letter-spacing: 0; overflow-wrap: anywhere; display: -webkit-box; -webkit-line-clamp: 2;
      -webkit-box-orient: vertical; overflow: hidden;
    }}
    .body {{ display: grid; grid-template-columns: minmax(0, 1.08fr) minmax(0, .92fr); gap: 20px; }}
    .left, .right {{ min-width: 0; display: grid; gap: 16px; }}
    .lead {{
      margin: 0; padding: 20px 24px; border-radius: 16px; background: #f5f7fb;
      border: 1px solid #d7dde7; font-size: 22px; line-height: 1.5; font-weight: 700;
      overflow: hidden; display: -webkit-box; -webkit-line-clamp: 3; -webkit-box-orient: vertical;
    }}
    section {{
      border-radius: 16px; border: 1px solid #d8d2c7; background: #ffffff;
      padding: 18px 22px; min-width: 0; overflow: hidden;
    }}
    h2 {{ margin: 0 0 12px; font-size: 18px; line-height: 1; color: {accent}; font-weight: 800; }}
    p {{ margin: 0; font-size: 19px; line-height: 1.5; font-weight: 700; overflow-wrap: anywhere; }}
    .detail {{ min-height: 242px; }}
    .detail p {{
      font-size: 18px; line-height: 1.56; font-weight: 680; color: #2f3845;
      display: -webkit-box; -webkit-line-clamp: 6; -webkit-box-orient: vertical; overflow: hidden;
    }}
    .use, .check {{ min-height: 118px; }}
    .use p, .check p {{
      display: -webkit-box; -webkit-line-clamp: 3; -webkit-box-orient: vertical; overflow: hidden;
    }}
    .muted {{ color: #53606d; font-size: 18px; line-height: 1.46; font-weight: 700; }}
    .path-card {{ min-height: 134px; }}
    .path {{
      display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 10px;
    }}
    .path div {{ min-width: 0; border-left: 5px solid {accent}; padding: 4px 0 4px 14px; }}
    .path span {{ display: block; color: #687281; font-size: 14px; font-weight: 800; margin-bottom: 8px; }}
    .path strong {{
      display: block; color: #151a23; font-size: 20px; line-height: 1.26; font-weight: 760;
      overflow-wrap: anywhere; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden;
    }}
  </style>
</head>
<body>
  <main class="page">
    <article class="card">
      <div class="rail"></div>
      <div class="content">
        <div class="meta"><span class="dot"></span><span>{html.escape(provider)}</span><span>·</span><span>{html.escape(kind)}</span></div>
        <h1>{html.escape(card_title)}</h1>
        <div class="body">
          <div class="left">
            <p class="lead">{html.escape(what_it_is)}</p>
            <section class="detail">
              <h2>詳細</h2>
              <p>{html.escape(detail)}</p>
            </section>
          </div>
          <div class="right">
            <section class="use">
              <h2>どういう場面で使えるか</h2>
              <p>{html.escape(use_case)}</p>
            </section>
            <section class="check">
              <h2>最初に確認すること</h2>
              <p class="muted">{html.escape(check_first)}</p>
            </section>
            <section class="path-card">
              <h2>使い方の目安</h2>
              <div class="path">
                <div><span>入口</span><strong>{html.escape(entry)}</strong></div>
                <div><span>操作</span><strong>{html.escape(action)}</strong></div>
                <div><span>結果</span><strong>{html.escape(result)}</strong></div>
              </div>
            </section>
          </div>
        </div>
      </div>
    </article>
  </main>
</body>
</html>
"""


def render_infographic_png(html_path: Path, png_path: Path, settings: dict[str, Any]) -> None:
    renderer = os.environ.get("HERMES_SUMMARY_PNG_RENDERER") or settings.get("summary_png_renderer", "playwright")
    if renderer == "playwright":
        npx = shutil.which("npx")
        if npx:
            try:
                subprocess.run(
                    [
                        npx,
                        "-y",
                        "playwright@latest",
                        "screenshot",
                        "--browser",
                        "chromium",
                        "--viewport-size=1200,675",
                        html_path.resolve().as_uri(),
                        str(png_path),
                    ],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=int(settings.get("summary_png_timeout_seconds", 45)),
                    check=True,
                )
                return
            except Exception:
                pass
    write_fallback_png(png_path)


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

    bg = (238, 242, 245)
    grid = (215, 222, 232)
    ink = (15, 23, 42)
    header = (20, 36, 58)
    cyan = (6, 182, 212)
    rose = (225, 29, 72)
    amber = (245, 158, 11)
    teal = (15, 118, 110)
    white = (255, 255, 255)

    def pixel_color(x: int, y: int) -> tuple[int, int, int]:
        if y < 178:
            return header if x < 760 else ink
        if 178 <= y < 182:
            return cyan
        if x % 32 == 0 or y % 32 == 0:
            return grid
        for left, top, right, bottom, color in [
            (48, 206, 568, 474, white),
            (48, 206, 568, 214, rose),
            (596, 206, 1152, 334, white),
            (596, 206, 604, 334, teal),
            (596, 358, 1152, 474, white),
            (596, 358, 604, 474, amber),
            (48, 502, 1152, 644, white),
        ]:
            if left <= x <= right and top <= y <= bottom:
                return color
        return bg

    rows = []
    for y in range(height):
        row = bytearray([0])
        for x in range(width):
            row.extend(pixel_color(x, y))
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
                    "summary_full": item.summary,
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
            for group_slug, group_label, grouped_candidates in split_candidates_for_route(route, route_candidates, settings):
                sent = send_candidates(
                    route,
                    grouped_candidates,
                    config,
                    settings,
                    env_file_values,
                    args.dry_run,
                    timeout,
                    state,
                    log_path,
                    group_slug,
                    group_label,
                )
                sent_count += sent
                if sent:
                    for candidate in grouped_candidates:
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
    group_slug: str | None = None,
    group_label: str | None = None,
) -> int:
    base_url = env_value(settings.get("webhook_base_url_env", ""), env_file_values) or settings.get("default_webhook_base_url", "http://127.0.0.1:8644")
    secret_env = settings.get("post_trigger_secret_env") if route != settings.get("default_route", "signal-catchup") else settings.get("secret_env")
    secret = env_value(secret_env or "", env_file_values)
    payload = build_payload(route, candidates, group_slug, group_label)
    url = route_url(base_url, route)
    cooldown_minutes = max(int(c.get("cooldown_minutes", settings.get("default_cooldown_minutes", 90))) for c in candidates)
    delivery_key = route if not group_slug else f"{route}:{group_slug}"
    log_group = f" group={group_label}" if group_label else ""
    last_sent = state.setdefault("last_sent_routes", {}).get(delivery_key, 0)
    now_ts = time.time()
    if last_sent and now_ts - float(last_sent) < cooldown_minutes * 60:
        log_line(log_path, f"cooldown route={route}{log_group} candidates={len(candidates)} minutes={cooldown_minutes}")
        return 0
    artifact = write_summary_artifacts(route, candidates, settings, group_slug, group_label)
    if artifact:
        payload["artifact"] = artifact
        log_line(log_path, f"summary artifacts route={route}{log_group} dir={artifact['artifact_dir']}")
    if dry_run:
        log_line(log_path, f"dry-run route={route}{log_group} candidates={len(candidates)}")
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
        state.setdefault("last_sent_routes", {})[delivery_key] = now_ts
        log_line(log_path, f"sent route={route}{log_group} candidates={len(candidates)} status={status} body={body[:200]}")
        return len(candidates)
    except Exception as exc:
        log_line(log_path, f"send failed route={route}{log_group} candidates={len(candidates)} error={exc}")
        send_alert(
            settings,
            "Hermes signal watcher webhook send failed",
            f"route={route}\ncandidates={len(candidates)}\nerror={exc}",
            log_path,
        )
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
