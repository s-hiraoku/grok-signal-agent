#!/usr/bin/env python3
"""Detect X/Twitter discussion pulses and trigger the Hermes tech digest."""

from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import os
import re
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


X_URL_RE = re.compile(r"https?://(?:x\.com|twitter\.com)/[^\s<>()\"']+", re.IGNORECASE)


def expand_path(value: str) -> Path:
    return Path(os.path.expandvars(os.path.expanduser(value)))


def now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


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


def log_line(path: Path, message: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as f:
        f.write(f"{now_iso()} {message}\n")


def canonical_x_url(url: str) -> str:
    cleaned = url.rstrip(".,;:!?)]}")
    parsed = urllib.parse.urlparse(cleaned)
    netloc = parsed.netloc.lower()
    if netloc == "twitter.com":
        netloc = "x.com"
    return urllib.parse.urlunparse(("https", netloc, parsed.path.rstrip("/"), "", "", ""))


def extract_x_urls(text: str) -> list[str]:
    seen: set[str] = set()
    urls: list[str] = []
    for match in X_URL_RE.findall(text):
        url = canonical_x_url(match)
        if url in seen:
            continue
        seen.add(url)
        urls.append(url)
    return urls


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
            "X-GitHub-Event": payload.get("event_type", "x.pulse"),
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.status, resp.read().decode("utf-8", errors="replace")


def build_prompt(config: dict[str, Any]) -> str:
    queries = "\n".join(f"- {query}" for query in config.get("queries", []))
    return f"""必ず x_search を使って、直近90分から最大3時間くらいの X/Twitter 上の developer/AI/Web/IT の盛り上がりを軽く確認してください。

目的は投稿本文の作成ではなく、tech digest を発火する価値がある X の動きがあるかを判定することです。

重点クエリ:
{queries}

条件:
- X/Twitter の直接 URL をできるだけ多く残す。
- 開発者、AI agent builder、Web engineer、IT watcher に意味がある話題を優先する。
- 同じ話題の重複や薄い感想は落とす。
- URL が確認できない話題は出さない。
- web_search や browser では代替しない。

出力は簡潔に:
1. pulse summary
2. high-signal X URLs with one-line reason
"""


def run_x_search(config: dict[str, Any], settings: dict[str, Any], sample_file: str | None) -> tuple[str, list[str]]:
    if sample_file:
        text = expand_path(sample_file).read_text(encoding="utf-8")
        return text, []

    hermes_bin = str(expand_path(settings.get("hermes_bin", "~/.local/bin/hermes")))
    prompt = build_prompt(config)
    timeout = int(settings.get("x_search_timeout_seconds", 240))
    proc = subprocess.run(
        [hermes_bin, "-t", "x_search", "-z", prompt],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        check=False,
    )
    errors = []
    if proc.stderr.strip():
        errors.append(proc.stderr.strip()[:1000])
    if proc.returncode != 0:
        raise RuntimeError(f"x_search failed exit={proc.returncode}: {proc.stderr.strip()[:1000]}")
    return proc.stdout, errors


def trim_seen_urls(state: dict[str, Any], max_seen_urls: int) -> None:
    seen = state.setdefault("seen_urls", {})
    if len(seen) <= max_seen_urls:
        return
    ordered = sorted(seen.items(), key=lambda item: item[1].get("first_seen_at", ""))
    state["seen_urls"] = dict(ordered[-max_seen_urls:])


def mark_seen_urls(state: dict[str, Any], urls: list[str]) -> None:
    seen = state.setdefault("seen_urls", {})
    for url in urls:
        seen.setdefault(url, {"first_seen_at": now_iso()})


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", default="config/x-pulse-watchers.json")
    parser.add_argument("--state")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--allow-first-run-send", action="store_true")
    parser.add_argument("--sample-file")
    args = parser.parse_args()

    config_path = expand_path(args.config)
    config = load_json(config_path, None)
    if not isinstance(config, dict) or config.get("version") != 1:
        print(f"invalid x pulse config: {config_path}", file=sys.stderr)
        return 2

    settings = config.get("settings", {})
    state_path = expand_path(args.state or settings.get("state_file", "~/.hermes/state/x-pulse-watcher-state.json"))
    log_path = expand_path(settings.get("log_file", "~/.hermes/logs/hermes-x-pulse-watcher.log"))
    env_file_values = load_env_file(expand_path(settings.get("env_file", "~/.hermes/.env")))
    state = load_json(state_path, {"seen_urls": {}, "sent": {}, "runs": []})
    first_run = not state.get("initialized")

    errors: list[str] = []
    try:
        curation, run_errors = run_x_search(config, settings, args.sample_file)
        errors.extend(run_errors)
    except Exception as exc:
        log_line(log_path, f"x_search failed error={exc}")
        print(json.dumps({"total_urls": 0, "new_urls": 0, "sent": 0, "errors": [str(exc)], "dry_run": args.dry_run}, ensure_ascii=False))
        return 1

    urls = extract_x_urls(curation)
    seen_urls = state.setdefault("seen_urls", {})
    new_urls = [url for url in urls if url not in seen_urls]
    score = len(new_urls) * 25 + len(urls) * 3
    min_new_urls = int(settings.get("min_new_urls", 4))
    min_total_urls = int(settings.get("min_total_urls", 6))
    min_score = int(settings.get("min_score", 120))
    should_prime_only = (
        first_run
        and settings.get("prime_only_on_first_run", True)
        and not args.allow_first_run_send
    )
    should_trigger = len(new_urls) >= min_new_urls and len(urls) >= min_total_urls and score >= min_score
    sent_count = 0

    if should_prime_only:
        mark_seen_urls(state, urls)
        log_line(log_path, f"primed total_urls={len(urls)}; no webhook sent")
    elif should_trigger:
        route = settings.get("route", "tech-digest-trigger")
        cooldown_minutes = int(settings.get("cooldown_minutes", 90))
        last_sent = state.setdefault("last_sent_routes", {}).get(route, 0)
        now_ts = time.time()
        if last_sent and now_ts - float(last_sent) < cooldown_minutes * 60:
            log_line(log_path, f"cooldown route={route} new_urls={len(new_urls)} minutes={cooldown_minutes}")
        elif args.dry_run:
            log_line(log_path, f"dry-run route={route} new_urls={len(new_urls)} score={score}")
        else:
            base_url = env_value(settings.get("webhook_base_url_env", ""), env_file_values) or settings.get("default_webhook_base_url", "http://127.0.0.1:8644")
            secret = env_value(settings.get("post_trigger_secret_env", ""), env_file_values)
            if not secret:
                log_line(log_path, "missing post trigger secret")
            else:
                payload = {
                    "event_type": "x.pulse",
                    "route": route,
                    "created_at": now_iso(),
                    "score": score,
                    "total_url_count": len(urls),
                    "new_url_count": len(new_urls),
                    "new_urls": new_urls,
                    "curation": curation[: int(settings.get("max_curation_chars", 6000))],
                }
                try:
                    status, body = post_webhook(route_url(base_url, route), secret, payload, int(settings.get("webhook_timeout_seconds", 20)))
                    state.setdefault("last_sent_routes", {})[route] = now_ts
                    state.setdefault("sent", {})[now_iso()] = {
                        "route": route,
                        "status": status,
                        "score": score,
                        "new_url_count": len(new_urls),
                    }
                    mark_seen_urls(state, urls)
                    sent_count = len(new_urls)
                    log_line(log_path, f"sent route={route} new_urls={len(new_urls)} status={status} body={body[:200]}")
                except Exception as exc:
                    log_line(log_path, f"send failed route={route} new_urls={len(new_urls)} error={exc}")
    else:
        log_line(log_path, f"below-threshold total_urls={len(urls)} new_urls={len(new_urls)} score={score}")

    state["initialized"] = True
    trim_seen_urls(state, int(settings.get("max_seen_urls", 400)))
    state.setdefault("runs", []).append({
        "at": now_iso(),
        "total_urls": len(urls),
        "new_urls": len(new_urls),
        "score": score,
        "should_trigger": should_trigger,
        "sent": sent_count,
        "errors": errors,
        "dry_run": args.dry_run,
    })
    state["runs"] = state["runs"][-50:]
    if not args.dry_run:
        save_json(state_path, state)

    print(json.dumps({
        "total_urls": len(urls),
        "new_urls": len(new_urls),
        "score": score,
        "should_trigger": should_trigger,
        "sent": sent_count,
        "errors": errors,
        "dry_run": args.dry_run,
        "prime_only": should_prime_only,
    }, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
