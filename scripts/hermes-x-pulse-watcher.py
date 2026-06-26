#!/usr/bin/env python3
"""Detect X/Twitter discussion pulses and trigger lightweight Hermes buzz posts."""

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
NUM_RE = re.compile(r"-?\d+")
COUNT_RE = re.compile(r"(?i)(\d+(?:,\d{3})*(?:\.\d+)?|\d+(?:\.\d+)?)([kmb])?")


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


def should_send_alert(state: dict[str, Any], key: str, settings: dict[str, Any]) -> bool:
    cooldown_seconds = int(settings.get("alert_cooldown_minutes", 60)) * 60
    alerts = state.setdefault("alerts", {})
    last_sent = alerts.get(key, 0)
    now_ts = time.time()
    if last_sent and now_ts - float(last_sent) < cooldown_seconds:
        return False
    alerts[key] = now_ts
    return True


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


def parse_int(value: str, default: int = 0) -> int:
    match = NUM_RE.search(str(value))
    if not match:
        return default
    return int(match.group(0))


def parse_count(value: str, default: int = 0) -> int:
    text = str(value).strip()
    match = COUNT_RE.search(text)
    if not match:
        return default
    number = float(match.group(1).replace(",", ""))
    suffix = (match.group(2) or "").lower()
    multiplier = {"k": 1_000, "m": 1_000_000, "b": 1_000_000_000}.get(suffix, 1)
    return int(number * multiplier)


def field_value(body: str, name: str) -> str:
    pattern = re.compile(rf"(?im)^\s*{re.escape(name)}\s*:\s*(.+?)\s*$")
    match = pattern.search(body)
    return match.group(1).strip() if match else ""


def parse_candidate_blocks(text: str) -> list[dict[str, Any]]:
    blocks = re.split(r"(?im)^\s*CANDIDATE\s*:?\s*$", text)
    candidates: list[dict[str, Any]] = []
    for block in blocks[1:]:
        urls = extract_x_urls(block)
        if not urls:
            continue
        likes = parse_count(field_value(block, "likes"))
        reposts = parse_count(field_value(block, "reposts"))
        replies = parse_count(field_value(block, "replies"))
        quotes = parse_count(field_value(block, "quotes"))
        views = max(parse_count(field_value(block, "views")), parse_count(field_value(block, "impressions")))
        independent_posts = parse_int(field_value(block, "independent_posts"), 1)
        posted_minutes_ago = parse_int(field_value(block, "posted_minutes_ago"), 9999)
        account_type = (field_value(block, "account_type") or "unknown").lower()
        candidates.append({
            "url": urls[0],
            "topic": field_value(block, "topic"),
            "posted_minutes_ago": posted_minutes_ago,
            "likes": likes,
            "reposts": reposts,
            "replies": replies,
            "quotes": quotes,
            "views": views,
            "independent_posts": independent_posts,
            "account_type": account_type,
            "reason": field_value(block, "reason"),
        })
    return candidates


def candidate_raw_engagement(candidate: dict[str, Any]) -> int:
    return (
        int(candidate.get("likes", 0))
        + int(candidate.get("reposts", 0)) * 4
        + int(candidate.get("replies", 0)) * 2
        + int(candidate.get("quotes", 0)) * 3
        + min(int(candidate.get("views", 0)) // 100, 300)
    )


def candidate_engagement(candidate: dict[str, Any]) -> int:
    return (
        candidate_raw_engagement(candidate)
        + max(0, int(candidate.get("independent_posts", 1)) - 1) * 10
    )


def is_qualified_candidate(candidate: dict[str, Any], settings: dict[str, Any]) -> tuple[bool, str]:
    minutes = int(candidate.get("posted_minutes_ago", 9999))
    likes = int(candidate.get("likes", 0))
    reposts = int(candidate.get("reposts", 0))
    replies_quotes = int(candidate.get("replies", 0)) + int(candidate.get("quotes", 0))
    views = int(candidate.get("views", 0))
    independent_posts = int(candidate.get("independent_posts", 1))
    account_type = str(candidate.get("account_type", "unknown")).lower()
    raw_engagement = candidate_raw_engagement(candidate)

    if account_type in {"bot", "aggregator", "spam"}:
        return False, "low-quality-account"

    early_window = int(settings.get("early_window_minutes", 120))
    max_window = int(settings.get("max_window_minutes", 240))
    if minutes > max_window:
        return False, "too-old"

    if account_type in {"official", "notable"} and (
        likes >= int(settings.get("min_likes_notable", 60))
        or reposts >= int(settings.get("min_reposts_notable", 8))
        or replies_quotes >= int(settings.get("min_replies_quotes_notable", 12))
        or views >= int(settings.get("min_views_notable", 5000))
    ):
        return True, "notable-account"

    if minutes <= early_window and (
        likes >= int(settings.get("min_likes_early", 100))
        or reposts >= int(settings.get("min_reposts_early", 15))
        or replies_quotes >= int(settings.get("min_replies_quotes_early", 20))
        or views >= int(settings.get("min_views_early", 10000))
    ):
        return True, "early-engagement"

    if (
        likes >= int(settings.get("min_likes_followup", 250))
        or reposts >= int(settings.get("min_reposts_followup", 35))
        or replies_quotes >= int(settings.get("min_replies_quotes_followup", 35))
        or views >= int(settings.get("min_views_followup", 30000))
    ):
        return True, "followup-engagement"

    if (
        independent_posts >= int(settings.get("min_cluster_posts", 5))
        and raw_engagement >= int(settings.get("min_cluster_engagement", 160))
    ):
        return True, "topic-cluster"

    return False, "weak-engagement"


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
    settings = config.get("settings", {})
    early_window = int(settings.get("early_window_minutes", 120))
    max_window = int(settings.get("max_window_minutes", 240))
    min_likes_early = int(settings.get("min_likes_early", 100))
    min_reposts_early = int(settings.get("min_reposts_early", 15))
    min_replies_quotes_early = int(settings.get("min_replies_quotes_early", 20))
    min_views_early = int(settings.get("min_views_early", 10000))
    min_likes_notable = int(settings.get("min_likes_notable", 60))
    min_reposts_notable = int(settings.get("min_reposts_notable", 8))
    min_replies_quotes_notable = int(settings.get("min_replies_quotes_notable", 12))
    min_views_notable = int(settings.get("min_views_notable", 5000))
    min_likes_followup = int(settings.get("min_likes_followup", 250))
    min_reposts_followup = int(settings.get("min_reposts_followup", 35))
    min_replies_quotes_followup = int(settings.get("min_replies_quotes_followup", 35))
    min_views_followup = int(settings.get("min_views_followup", 30000))
    min_cluster_posts = int(settings.get("min_cluster_posts", 5))
    min_cluster_engagement = int(settings.get("min_cluster_engagement", 160))
    return f"""必ず x_search を使って、直近{early_window}分を優先し、反応確認のため最大{max_window}分までの X/Twitter 上の developer/AI/Web/IT の盛り上がりを軽く確認してください。

目的は投稿本文の作成ではなく、軽量な X バズ紹介を投稿する価値がある動きがあるかを判定することです。朝/昼/晩の full tech digest は別の cronjob が担当します。

重点クエリ:
{queries}

条件:
- X/Twitter の直接 URL を、反応が確認できる候補だけ残す。
- 各 URL は https://x.com/<handle>/status/<id> または https://twitter.com/<handle>/status/<id> の完全な直接 URL にする。
- 各候補に likes / reposts / replies / quotes / views / posted_minutes_ago / account_type / independent_posts を必ず付ける。views が見えない場合は 0 にする。
- 採用候補は、直近{early_window}分で likes>={min_likes_early}、reposts>={min_reposts_early}、replies+quotes>={min_replies_quotes_early}、views>={min_views_early} のいずれかを満たすものに絞る。
- 公式/著名アカウントでも likes>={min_likes_notable}、reposts>={min_reposts_notable}、replies+quotes>={min_replies_quotes_notable}、views>={min_views_notable} のいずれかが確認できないものは採用しない。
- {early_window}分を超えて最大{max_window}分まで見る場合は likes>={min_likes_followup}、reposts>={min_reposts_followup}、replies+quotes>={min_replies_quotes_followup}、views>={min_views_followup} のいずれかを満たすものに絞る。
- 同一topicの独立投稿クラスタは、独立投稿が{min_cluster_posts}件以上あり、かつ対象投稿単体にも raw engagement score>={min_cluster_engagement} 相当の反応がある場合だけ採用する。独立投稿数だけでは採用しない。
- 開発者、AI agent builder、Web engineer、IT watcher に意味がある話題を優先する。
- 同じ話題の重複や薄い感想は落とす。
- engagement 数値が不明な投稿、反応が薄い投稿、単なるリンク転載、自動投稿/botっぽい投稿、URL が確認できない話題は出さない。
- web_search や browser では代替しない。

出力は必ず次の候補ブロックだけにしてください。候補がなければ `NO_QUALIFIED_PULSE` とだけ返してください。

CANDIDATE
topic: <短い話題名>
url: <direct X URL>
posted_minutes_ago: <number>
likes: <number>
reposts: <number>
replies: <number>
quotes: <number>
views: <number, 0 if unavailable>
account_type: official|notable|general|bot|aggregator|unknown
independent_posts: <same-topic independent post count>
reason: <why this matters in Japanese>
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
        if should_send_alert(state, "x-search-failed", settings):
            send_alert(
                settings,
                "Hermes X pulse watcher x_search failed",
                str(exc),
                log_path,
            )
        if not args.dry_run:
            save_json(state_path, state)
        print(json.dumps({"total_urls": 0, "new_urls": 0, "sent": 0, "errors": [str(exc)], "dry_run": args.dry_run}, ensure_ascii=False))
        return 1

    urls = extract_x_urls(curation)
    parsed_candidates = parse_candidate_blocks(curation)
    seen_urls = state.setdefault("seen_urls", {})
    qualified_candidates = []
    rejected_candidates = []
    for candidate in parsed_candidates:
        qualified, reason = is_qualified_candidate(candidate, settings)
        candidate["qualification"] = reason
        if qualified and candidate["url"] not in seen_urls:
            qualified_candidates.append(candidate)
        else:
            rejected_candidates.append(candidate)
    new_urls = [candidate["url"] for candidate in qualified_candidates]
    score = sum(candidate_engagement(candidate) for candidate in qualified_candidates)
    min_qualified_urls = int(settings.get("min_qualified_urls", 1))
    min_qualified_score = int(settings.get("min_qualified_score", 40))
    should_prime_only = (
        first_run
        and settings.get("prime_only_on_first_run", True)
        and not args.allow_first_run_send
    )
    should_trigger = len(new_urls) >= min_qualified_urls and score >= min_qualified_score
    sent_count = 0

    if should_prime_only:
        mark_seen_urls(state, urls)
        log_line(log_path, f"primed total_urls={len(urls)} qualified={len(qualified_candidates)}; no webhook sent")
    elif should_trigger:
        route = settings.get("route", "x-buzz-trigger")
        cooldown_minutes = int(settings.get("cooldown_minutes", 90))
        last_sent = state.setdefault("last_sent_routes", {}).get(route, 0)
        now_ts = time.time()
        if last_sent and now_ts - float(last_sent) < cooldown_minutes * 60:
            log_line(log_path, f"cooldown route={route} new_urls={len(new_urls)} minutes={cooldown_minutes}")
        elif args.dry_run:
            log_line(log_path, f"dry-run route={route} qualified_urls={len(new_urls)} score={score}")
        else:
            base_url = env_value(settings.get("webhook_base_url_env", ""), env_file_values) or settings.get("default_webhook_base_url", "http://127.0.0.1:8644")
            secret = env_value(settings.get("post_trigger_secret_env", ""), env_file_values)
            if not secret:
                log_line(log_path, "missing post trigger secret")
                if should_send_alert(state, f"missing-secret:{route}", settings):
                    send_alert(
                        settings,
                        "Hermes X pulse watcher missing webhook secret",
                        f"route={route}\nqualified_urls={len(new_urls)}\nsecret_env={settings.get('post_trigger_secret_env', '')}",
                        log_path,
                    )
            else:
                payload = {
                    "event_type": "x.pulse",
                    "route": route,
                    "summary_kind": "x_buzz_posts",
                    "created_at": now_iso(),
                    "score": score,
                    "total_url_count": len(urls),
                    "new_url_count": len(new_urls),
                    "new_urls": new_urls,
                    "buzz_urls": new_urls,
                    "qualified_candidates": qualified_candidates,
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
                    log_line(log_path, f"sent route={route} qualified_urls={len(new_urls)} score={score} status={status} body={body[:200]}")
                except Exception as exc:
                    log_line(log_path, f"send failed route={route} qualified_urls={len(new_urls)} error={exc}")
                    if should_send_alert(state, f"send-failed:{route}", settings):
                        send_alert(
                            settings,
                            "Hermes X pulse watcher webhook send failed",
                            f"route={route}\nqualified_urls={len(new_urls)}\nerror={exc}",
                            log_path,
                        )
    else:
        log_line(log_path, f"below-threshold total_urls={len(urls)} candidates={len(parsed_candidates)} qualified_urls={len(new_urls)} score={score}")

    state["initialized"] = True
    trim_seen_urls(state, int(settings.get("max_seen_urls", 400)))
    state.setdefault("runs", []).append({
        "at": now_iso(),
        "total_urls": len(urls),
        "new_urls": len(new_urls),
        "candidate_count": len(parsed_candidates),
        "qualified_count": len(qualified_candidates),
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
        "candidate_count": len(parsed_candidates),
        "qualified_count": len(qualified_candidates),
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
