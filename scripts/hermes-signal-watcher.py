#!/usr/bin/env python3
"""Detect meaningful source changes and trigger Hermes webhooks.

The watcher is intentionally separate from Hermes. It polls source feeds/pages,
dedupes items, scores new signals, and POSTs only threshold-crossing payloads
to Hermes webhook routes.
"""

from __future__ import annotations

import argparse
import email.utils
import hashlib
import hmac
import html
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from datetime import datetime, timezone
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
    include = source.get("include_url_patterns", [])
    exclude = source.get("exclude_url_patterns", [])
    seen: set[str] = set()
    items: list[SignalItem] = []
    pattern = re.compile(
        r"<a\b[^>]*href=[\"']([^\"']+)[\"'][^>]*>(.*?)</a>",
        re.IGNORECASE | re.DOTALL,
    )
    for href, inner in pattern.findall(text):
        url = urllib.parse.urljoin(base_url, html.unescape(href))
        parsed = urllib.parse.urlparse(url)
        path = parsed.path
        if include and not any(p in path for p in include):
            continue
        if exclude and any(p in path for p in exclude):
            continue
        if url in seen:
            continue
        title = normalize_space(re.sub(r"<[^>]+>", " ", inner))
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
        if keyword.lower() in haystack:
            score += int(weight)
            reasons.append(f"{keyword}+{weight}")
    return score, reasons


def route_url(base_url: str, route: str) -> str:
    return base_url.rstrip("/") + "/webhooks/" + route.lstrip("/")


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


def build_payload(route: str, candidates: list[dict[str, Any]]) -> dict[str, Any]:
    return {
        "event_type": "signal.batch" if len(candidates) > 1 else "signal.item",
        "route": route,
        "created_at": now_iso(),
        "candidate_count": len(candidates),
        "signals": candidates,
    }


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
    candidates: list[dict[str, Any]] = []
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
            else:
                errors.append(f"{source.get('id')}: unsupported type {source.get('type')}")
                continue
        except (urllib.error.URLError, TimeoutError, ET.ParseError, OSError, ValueError) as exc:
            errors.append(f"{source.get('id')}: {exc}")
            continue

        for item in items[:max_items]:
            observed.append(item)
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

    for item in observed:
        state.setdefault("seen", {}).setdefault(item.stable_key, {
            "first_seen_at": now_iso(),
            "source_id": item.source_id,
            "title": item.title,
            "url": item.url,
        })

    candidates.sort(key=lambda c: c["score"], reverse=True)
    should_prime_only = (
        first_run
        and settings.get("prime_only_on_first_run", True)
        and not args.allow_first_run_send
    )
    sent_count = 0

    if should_prime_only:
        log_line(log_path, f"primed {len(observed)} observed items; no webhook sent")
    else:
        batch_min_items = int(settings.get("batch_min_items", 4))
        batch_min_score = int(settings.get("batch_min_score", 220))
        total_score = sum(c["score"] for c in candidates)
        if len(candidates) >= batch_min_items and total_score >= batch_min_score:
            batch_route = settings.get("batch_route", "tech-digest-trigger")
            sent_count += send_candidates(batch_route, candidates, config, settings, env_file_values, args.dry_run, timeout, state, log_path)
        else:
            for candidate in candidates:
                sent_count += send_candidates(candidate["route"], [candidate], config, settings, env_file_values, args.dry_run, timeout, state, log_path)

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
    if dry_run:
        log_line(log_path, f"dry-run route={route} candidates={len(candidates)}")
        return 0
    if not secret:
        log_line(log_path, f"missing secret env for route={route} env={secret_env}")
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
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
