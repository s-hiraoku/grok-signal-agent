#!/usr/bin/env bash
set -euo pipefail

LOG_DIR="${HERMES_LOG_DIR:-${HOME}/.hermes/logs}"
LOG_FILE="${LOG_DIR}/hermes-morning-brief-cron.log"
PYTHON_BIN="${PYTHON_BIN:-python3}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -z "${HERMES_CRONJOBS_CONFIG:-}" ]]; then
  cronjobs_config="${REPO_DIR}/config/hermes-cronjobs.json"
  runtime_dir="${HERMES_POSTING_RUNTIME:-${HOME}/.hermes/runtime/grok-signal-agent}"
  if [[ ! -f "${cronjobs_config}" && -f "${runtime_dir}/config/hermes-cronjobs.json" ]]; then
    cronjobs_config="${runtime_dir}/config/hermes-cronjobs.json"
  elif [[ ! -f "${cronjobs_config}" && -f "${runtime_dir}/repo-path" ]]; then
    repo_hint="$(<"${runtime_dir}/repo-path")"
    if [[ -f "${repo_hint}/config/hermes-cronjobs.json" ]]; then
      cronjobs_config="${repo_hint}/config/hermes-cronjobs.json"
    fi
  fi
  export HERMES_CRONJOBS_CONFIG="${cronjobs_config}"
fi

mkdir -p "${LOG_DIR}"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$*" >> "${LOG_FILE}"
}

log "starting morning brief cron"

"${PYTHON_BIN}" <<'PY'
from __future__ import annotations

import email.utils
import html
import json
import os
import re
import subprocess
import sys
import textwrap
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path


DEFAULT_GENERAL_FEEDS = [
    ("NHK NEWS WEB", "https://www.nhk.or.jp/rss/news/cat0.xml"),
]

DEFAULT_TECH_FEEDS = [
    ("GitHub Changelog", "https://github.blog/changelog/feed/"),
    ("OpenAI News", "https://openai.com/news/rss.xml"),
    ("Addy Osmani Blog", "https://addyosmani.com/rss.xml"),
    ("Cloudflare Changelog", "https://developers.cloudflare.com/changelog/rss/index.xml"),
    ("Publickey", "https://www.publickey1.jp/atom.xml"),
    ("Zenn", "https://zenn.dev/feed"),
]

MAX_GENERAL = int(os.environ.get("HERMES_MORNING_MAX_GENERAL", "5"))
MAX_TECH = int(os.environ.get("HERMES_MORNING_MAX_TECH", "5"))
MAX_TODAY_EVENTS = int(os.environ.get("HERMES_MORNING_MAX_TODAY_EVENTS", "6"))
MAX_WEEK_EVENTS = int(os.environ.get("HERMES_MORNING_MAX_WEEK_EVENTS", "10"))
RECENT_HOURS = int(os.environ.get("HERMES_MORNING_RECENT_HOURS", "36"))
USER_AGENT = os.environ.get("HERMES_MORNING_USER_AGENT", "HermesMorningBrief/1.0")
CALENDAR_ENABLED = os.environ.get("HERMES_MORNING_CALENDAR_ENABLED", "1") != "0"
GOOGLE_API_SCRIPT = os.environ.get(
    "HERMES_GOOGLE_API_SCRIPT",
    str(Path.home() / ".hermes/skills/productivity/google-workspace/scripts/google_api.py"),
)
DEFAULT_GOOGLE_API_PYTHON = Path.home() / ".hermes/hermes-agent/venv/bin/python"
GOOGLE_API_PYTHON = os.environ.get(
    "HERMES_GOOGLE_API_PYTHON",
    str(DEFAULT_GOOGLE_API_PYTHON) if DEFAULT_GOOGLE_API_PYTHON.exists() else sys.executable,
)
CRONJOBS_CONFIG = Path(os.environ.get("HERMES_CRONJOBS_CONFIG", ""))
MORNING_BRIEF_TIME_LABEL = os.environ.get("HERMES_MORNING_BRIEF_TIME_LABEL", "").strip()


@dataclass
class Item:
    source: str
    title: str
    url: str
    published: datetime | None


@dataclass
class CalendarEvent:
    summary: str
    start: datetime | None
    end: datetime | None
    location: str
    html_link: str


def local_tz() -> timezone:
    offset = -time.timezone
    if time.localtime().tm_isdst and time.daylight:
        offset = -time.altzone
    return timezone(timedelta(seconds=offset))


def current_time() -> datetime:
    override = os.environ.get("HERMES_MORNING_NOW", "").strip()
    if override:
        dt = datetime.fromisoformat(override.replace("Z", "+00:00"))
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=local_tz())
        return dt.astimezone(timezone.utc)
    return datetime.now(timezone.utc)


def cron_schedule_time_label(schedule: str) -> str:
    parts = schedule.split()
    if len(parts) < 2:
        return ""
    minute_raw, hour_raw = parts[0], parts[1]
    if not re.fullmatch(r"\d{1,2}", minute_raw) or not re.fullmatch(r"\d{1,2}", hour_raw):
        return ""
    minute = int(minute_raw)
    hour = int(hour_raw)
    if not (0 <= minute <= 59 and 0 <= hour <= 23):
        return ""
    return f"{hour}:{minute:02d}"


def morning_brief_time_label() -> str:
    if MORNING_BRIEF_TIME_LABEL:
        return MORNING_BRIEF_TIME_LABEL
    if not CRONJOBS_CONFIG.is_file():
        return ""
    try:
        config = json.loads(CRONJOBS_CONFIG.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return ""
    # Assumes at most one enabled job runs this script; with several, the
    # first match in config order decides the label.
    for job in config.get("jobs", []):
        if job.get("enabled", True) is not True:
            continue
        if job.get("script") != "hermes-morning-brief-cron.sh":
            continue
        label = cron_schedule_time_label(str(job.get("schedule", "")))
        if label:
            return label
    return ""


def parse_feed_env(name: str, default: list[tuple[str, str]]) -> list[tuple[str, str]]:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    feeds: list[tuple[str, str]] = []
    for line in raw.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "|" not in line:
            continue
        source, url = line.split("|", 1)
        source = source.strip()
        url = url.strip()
        if source and url:
            feeds.append((source, url))
    return feeds or default


def fetch_url(url: str) -> bytes:
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme == "file":
        return Path(urllib.request.url2pathname(parsed.path)).read_bytes()
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=20) as response:
        return response.read()


def clean_text(value: str | None) -> str:
    if not value:
        return ""
    value = html.unescape(value)
    value = re.sub(r"<[^>]+>", "", value)
    return re.sub(r"\s+", " ", value).strip()


def child_text(element: ET.Element, names: set[str]) -> str:
    for child in list(element):
        local = child.tag.rsplit("}", 1)[-1].lower()
        if local in names and child.text:
            return clean_text(child.text)
    return ""


def parse_date(value: str) -> datetime | None:
    value = clean_text(value)
    if not value:
        return None
    try:
        dt = email.utils.parsedate_to_datetime(value)
    except (TypeError, ValueError):
        try:
            normalized = value.replace("Z", "+00:00")
            dt = datetime.fromisoformat(normalized)
        except ValueError:
            return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def parse_event_time(value: str) -> datetime | None:
    value = str(value or "").strip()
    if not value:
        return None
    try:
        dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        try:
            dt = datetime.fromisoformat(value + "T00:00:00")
        except ValueError:
            return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=local_tz())
    return dt.astimezone(timezone.utc)


def atom_link(entry: ET.Element) -> str:
    fallback = ""
    for child in list(entry):
        if child.tag.rsplit("}", 1)[-1].lower() != "link":
            continue
        href = child.attrib.get("href", "").strip()
        if not href:
            continue
        if child.attrib.get("rel", "alternate") == "alternate":
            return href
        fallback = fallback or href
    return fallback


def parse_items(source: str, data: bytes) -> list[Item]:
    root = ET.fromstring(data)
    root_name = root.tag.rsplit("}", 1)[-1].lower()
    items: list[Item] = []
    if root_name == "feed":
        entries = [el for el in root.iter() if el.tag.rsplit("}", 1)[-1].lower() == "entry"]
        for entry in entries:
            title = child_text(entry, {"title"})
            url = atom_link(entry)
            published = parse_date(child_text(entry, {"published", "updated"}))
            if title and url:
                items.append(Item(source, title, url, published))
        return items

    rss_items = [el for el in root.iter() if el.tag.rsplit("}", 1)[-1].lower() == "item"]
    for item in rss_items:
        title = child_text(item, {"title"})
        url = child_text(item, {"link", "guid"})
        published = parse_date(child_text(item, {"pubdate", "date", "updated"}))
        if title and url:
            items.append(Item(source, title, url, published))
    return items


def collect(feeds: list[tuple[str, str]]) -> tuple[list[Item], list[str]]:
    collected: list[Item] = []
    errors: list[str] = []
    for source, url in feeds:
        try:
            collected.extend(parse_items(source, fetch_url(url)))
        except Exception as exc:
            errors.append(f"{source}: {exc}")
    deduped: list[Item] = []
    seen: set[str] = set()
    for item in collected:
        key = item.url.rstrip("/")
        if key in seen:
            continue
        seen.add(key)
        deduped.append(item)
    deduped.sort(key=lambda item: item.published or datetime.min.replace(tzinfo=timezone.utc), reverse=True)
    return deduped, errors


def select_items(items: list[Item], limit: int, now: datetime) -> list[Item]:
    cutoff = now - timedelta(hours=RECENT_HOURS)
    recent = [item for item in items if item.published is not None and item.published >= cutoff]
    selected = recent[:limit]
    if len(selected) < limit:
        for item in items:
            if item in selected:
                continue
            selected.append(item)
            if len(selected) >= limit:
                break
    return selected


def date_label(item: Item, tz: timezone) -> str:
    if item.published is None:
        return item.source
    return f"{item.source} / {item.published.astimezone(tz).strftime('%m/%d %H:%M')}"


def section(title: str, items: list[Item], limit_note: str, tz: timezone) -> str:
    lines = [title]
    if not items:
        lines.append(f"- {limit_note}")
        return "\n".join(lines)
    for item in items:
        lines.append(f"- {item.title}")
        lines.append(f"  出典: {item.url}")
        lines.append(f"  確認: {date_label(item, tz)}")
    return "\n".join(lines)


def iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def fetch_calendar_events(start: datetime, end: datetime, limit: int) -> tuple[list[CalendarEvent], str]:
    if not CALENDAR_ENABLED:
        return [], ""
    script = Path(GOOGLE_API_SCRIPT).expanduser()
    if not script.exists():
        return [], "Google Workspace skill の calendar helper が見つからなかったよ。"
    cmd = [
        GOOGLE_API_PYTHON,
        str(script),
        "calendar",
        "list",
        "--start",
        iso(start),
        "--end",
        iso(end),
        "--max",
        str(limit),
    ]
    try:
        completed = subprocess.run(cmd, check=False, text=True, capture_output=True, timeout=25)
    except Exception as exc:
        return [], f"Google Calendar 予定取得でエラー: {exc}"
    if completed.returncode != 0:
        message = [line.strip() for line in (completed.stderr or completed.stdout or "").splitlines() if line.strip()]
        detail = message[-1] if message else f"exit {completed.returncode}"
        return [], f"Google Calendar 予定取得に失敗: {detail}"
    try:
        payload = json.loads(completed.stdout or "[]")
    except json.JSONDecodeError as exc:
        return [], f"Google Calendar 予定取得結果を読めなかったよ: {exc}"
    events: list[CalendarEvent] = []
    for raw in payload if isinstance(payload, list) else []:
        if not isinstance(raw, dict):
            continue
        summary = clean_text(str(raw.get("summary") or "(タイトルなし)"))
        events.append(
            CalendarEvent(
                summary=summary,
                start=parse_event_time(str(raw.get("start") or "")),
                end=parse_event_time(str(raw.get("end") or "")),
                location=clean_text(str(raw.get("location") or "")),
                html_link=str(raw.get("htmlLink") or "").strip(),
            )
        )
    events.sort(key=lambda event: event.start or datetime.max.replace(tzinfo=timezone.utc))
    return events, ""


def event_time_label(event: CalendarEvent, tz: timezone) -> str:
    if event.start is None:
        return "時刻未設定"
    start = event.start.astimezone(tz)
    if event.end is None:
        return start.strftime("%m/%d %H:%M")
    end = event.end.astimezone(tz)
    if start.date() == end.date():
        return f"{start.strftime('%m/%d %H:%M')}-{end.strftime('%H:%M')}"
    return f"{start.strftime('%m/%d %H:%M')}-{end.strftime('%m/%d %H:%M')}"


def calendar_section(title: str, events: list[CalendarEvent], empty_note: str, tz: timezone, error: str = "") -> str:
    lines = [title]
    if error:
        lines.append(f"- {error}")
        return "\n".join(lines)
    if not events:
        lines.append(f"- {empty_note}")
        return "\n".join(lines)
    for event in events:
        detail = event_time_label(event, tz)
        if event.location:
            detail += f" / {event.location}"
        lines.append(f"- {detail} {event.summary}")
        if event.html_link:
            lines.append(f"  予定: {event.html_link}")
    return "\n".join(lines)


def compact_summary(value: str, limit: int = 52) -> str:
    value = clean_text(value)
    if len(value) <= limit:
        return value
    return value[: limit - 1].rstrip() + "…"


def morning_overview(
    events: list[CalendarEvent],
    calendar_error: str,
    general_items: list[Item],
    tech_items: list[Item],
    tz: timezone,
) -> str:
    schedule_count = "取得失敗" if calendar_error else f"{len(events)}件"
    lines = [
        f"今朝の概要｜予定 {schedule_count}・一般 {len(general_items)}件・Tech/AI {len(tech_items)}件"
    ]
    if calendar_error:
        lines.append("- 予定: カレンダーを取得できなかったため本文に状況を記載")
    elif events:
        first_event = events[0]
        lines.append(
            f"- 予定: {event_time_label(first_event, tz)} {compact_summary(first_event.summary)}"
        )
    else:
        lines.append("- 予定: 登録なし")
    if general_items:
        lines.append(f"- 一般: {compact_summary(general_items[0].title)}")
    else:
        lines.append("- 一般: 主要項目なし")
    if tech_items:
        lines.append(f"- Tech/AI: {compact_summary(tech_items[0].title)}")
    else:
        lines.append("- Tech/AI: 主要項目なし")
    return "\n".join(lines)


def main() -> int:
    now = current_time()
    tz = local_tz()
    local_now = now.astimezone(tz)
    brief_time_label = morning_brief_time_label()
    brief_name = f"{brief_time_label} の morning brief" if brief_time_label else "morning brief"
    today_start = datetime(local_now.year, local_now.month, local_now.day, tzinfo=tz)
    today_end = today_start + timedelta(days=1)
    week_start = today_start - timedelta(days=today_start.weekday())
    week_end = week_start + timedelta(days=7)
    general_feeds = parse_feed_env("HERMES_MORNING_GENERAL_FEEDS", DEFAULT_GENERAL_FEEDS)
    tech_feeds = parse_feed_env("HERMES_MORNING_TECH_FEEDS", DEFAULT_TECH_FEEDS)
    general_items, general_errors = collect(general_feeds)
    tech_items, tech_errors = collect(tech_feeds)
    selected_general = select_items(general_items, MAX_GENERAL, now)
    selected_tech = select_items(tech_items, MAX_TECH, now)
    today_events, today_calendar_error = fetch_calendar_events(today_start, today_end, MAX_TODAY_EVENTS)
    week_events: list[CalendarEvent] = []
    week_calendar_error = ""
    is_monday = local_now.weekday() == 0
    if is_monday:
        week_events, week_calendar_error = fetch_calendar_events(week_start, week_end, MAX_WEEK_EVENTS)

    error_note = ""
    errors = general_errors + tech_errors
    if errors:
        error_note = "\n\n取得メモ: 一部ソースは取得できなかったよ。確認できたソースを優先して載せています。"

    overview = morning_overview(
        today_events,
        today_calendar_error,
        selected_general,
        selected_tech,
        tz,
    )

    body = f"""{overview}

おはよう、ヘルメスちゃんです！

もうすぐ仕事だよー。{brief_name} だよ。ニュースは直接フィードから確認できたものを優先して拾ってきたよ☀️

{calendar_section("今日の予定", today_events, "今日の予定は見つからなかったよ。集中作業や仕込みに使えそうです。", tz, today_calendar_error)}
"""
    if is_monday:
        body += f"""

{calendar_section("今週の予定", week_events, "今週の予定は見つからなかったよ。週の計画を先に置いておくとよさそうです。", tz, week_calendar_error)}
"""
    body += f"""

{section("今日の一般ニュース", selected_general, "主要フィードから確認できる項目が少なめです。必要ならNHKなどの一次ソースを直接確認してね。", tz)}

{section("今日のTech/AI/開発ニュース", selected_tech, "Tech/AI/開発フィードから確認できる項目が少なめです。昼のtech digestでもう一度追います。", tz)}

今日の優先順位確認
- まず締切・連絡待ち・ブロッカーを確認してね。
- ニュースで仕事に関係しそうな項目があれば、あとで深掘りする候補に置いておこう。
- 今日も無理なく、重要なところから進めよーだよ。{error_note}
"""
    print(textwrap.dedent(body).strip())
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(
            "おはよう、ヘルメスちゃんです！\n\n"
            "morning brief のニュース取得で想定外のエラーが出ました。"
            "今日は直接ソースを確認してね。\n"
            f"取得エラー: {exc}"
        )
        raise SystemExit(0)
PY
