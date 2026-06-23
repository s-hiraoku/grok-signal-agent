#!/usr/bin/env python3
"""Small mnemo-like memory layer for Hermes.

The store is intentionally local and conservative: Discord event capture only
records messages from explicitly configured memory channels, while recall is an
on-demand command that searches saved memory and knowledge pages.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import sqlite3
import sys
from pathlib import Path
from typing import Iterable


WIKILINK_RE = re.compile(r"(?<!`)\[\[([^\]\n]+)\]\](?!`)")


def now_utc() -> str:
    return dt.datetime.now(dt.UTC).replace(microsecond=0).isoformat()


def expand_path(value: str) -> Path:
    return Path(os.path.expandvars(os.path.expanduser(value)))


def default_db_path() -> Path:
    return expand_path(os.environ.get("HERMES_MNEMO_DB", "~/.hermes/mnemo/mnemo.sqlite"))


def default_export_dir() -> Path:
    return expand_path(os.environ.get("HERMES_MNEMO_EXPORT_DIR", "~/.hermes/mnemo/knowledge"))


def normalize_slug(value: str) -> str:
    value = value.strip().lower()
    value = re.sub(r"\[\[|\]\]", "", value)
    value = re.sub(r"[^0-9a-zA-Zぁ-んァ-ン一-龥ー_-]+", "-", value)
    value = re.sub(r"-{2,}", "-", value).strip("-_")
    return value[:80] or "memory"


def make_slug(body: str, created_at: str) -> str:
    stamp = created_at.replace("-", "").replace(":", "").replace("+00:00", "Z")
    stamp = stamp.replace("T", "-")
    head = normalize_slug(body.splitlines()[0])[:48]
    return f"{stamp}-{head}"


def unique_slug(conn: sqlite3.Connection, slug: str) -> str:
    candidate = slug
    counter = 2
    while conn.execute(
        """
        SELECT 1 FROM memory WHERE slug = ?
        UNION ALL
        SELECT 1 FROM knowledge WHERE slug = ?
        LIMIT 1
        """,
        (candidate, candidate),
    ).fetchone():
        candidate = f"{slug}-{counter}"
        counter += 1
    return candidate


def extract_wikilinks(text: str) -> list[str]:
    links: list[str] = []
    for match in WIKILINK_RE.finditer(text):
        slug = normalize_slug(match.group(1))
        if slug and slug not in links:
            links.append(slug)
    return links


def extract_text_field(data: object) -> str:
    if isinstance(data, str):
        match = re.search(r"(?:text|content)='([^']*)'", data)
        return match.group(1) if match else data
    if not isinstance(data, dict):
        return ""
    for key in ("text", "message", "content"):
        value = data.get(key)
        if isinstance(value, str):
            return value
    for key in ("event", "extra"):
        value = data.get(key)
        text = extract_text_field(value)
        if text:
            return text
    return ""


def extract_first(data: object, keys: Iterable[str]) -> str:
    if isinstance(data, dict):
        for key in keys:
            value = data.get(key)
            if isinstance(value, str):
                return value
            if isinstance(value, dict):
                nested = extract_first(value, keys)
                if nested:
                    return nested
        for key in ("event", "extra", "author", "message"):
            value = data.get(key)
            nested = extract_first(value, keys)
            if nested:
                return nested
    elif isinstance(data, str):
        for key in keys:
            match = re.search(rf"{re.escape(key)}='([^']*)'", data)
            if match:
                return match.group(1)
    return ""


def allowed_channel_ids() -> set[str]:
    raw = os.environ.get("HERMES_MNEMO_MEMORY_CHANNEL_IDS", "")
    return {part.strip() for part in re.split(r"[, \n]+", raw) if part.strip()}


def connect(db_path: Path) -> sqlite3.Connection:
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    conn.executescript(
        """
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS memory (
          slug TEXT PRIMARY KEY,
          body TEXT NOT NULL,
          source TEXT NOT NULL DEFAULT 'manual',
          stage TEXT NOT NULL DEFAULT 'seedling',
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          last_viewed_at TEXT,
          view_count INTEGER NOT NULL DEFAULT 0,
          metadata_json TEXT NOT NULL DEFAULT '{}'
        );
        CREATE TABLE IF NOT EXISTS knowledge (
          slug TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          body TEXT NOT NULL,
          source TEXT NOT NULL DEFAULT 'manual',
          stage TEXT NOT NULL DEFAULT 'seedling',
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          last_viewed_at TEXT,
          view_count INTEGER NOT NULL DEFAULT 0,
          metadata_json TEXT NOT NULL DEFAULT '{}'
        );
        CREATE TABLE IF NOT EXISTS knowledge_links (
          from_slug TEXT NOT NULL,
          to_slug TEXT NOT NULL,
          resource_type TEXT NOT NULL,
          created_at TEXT NOT NULL,
          PRIMARY KEY (from_slug, to_slug, resource_type)
        );
        CREATE TABLE IF NOT EXISTS knowledge_synonyms (
          term TEXT PRIMARY KEY,
          synonyms_json TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS sessions (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          event_type TEXT NOT NULL,
          resource_type TEXT,
          slug TEXT,
          body TEXT,
          created_at TEXT NOT NULL,
          metadata_json TEXT NOT NULL DEFAULT '{}'
        );
        """
    )
    return conn


def is_knowledge_note(text: str) -> bool:
    lowered = text.lower()
    return "source:" in lowered and "why captured:" in lowered and "connections:" in lowered


def title_from_text(text: str) -> str:
    for line in text.splitlines():
        stripped = line.strip().lstrip("#").strip()
        if stripped:
            return stripped[:120]
    return "Untitled memory"


def export_markdown(
    export_dir: Path,
    resource_type: str,
    slug: str,
    title: str,
    body: str,
    source: str,
    stage: str,
    created_at: str,
    metadata: dict[str, str],
) -> None:
    target_dir = export_dir / resource_type
    target_dir.mkdir(parents=True, exist_ok=True)
    path = target_dir / f"{slug}.md"
    frontmatter = {
        "type": resource_type,
        "slug": slug,
        "stage": stage,
        "source": source,
        "created_at": created_at,
        **{k: v for k, v in metadata.items() if v},
    }
    with path.open("w", encoding="utf-8") as fh:
        fh.write("---\n")
        for key, value in frontmatter.items():
            fh.write(f'{key}: "{str(value).replace(chr(34), chr(92) + chr(34))}"\n')
        fh.write("---\n\n")
        if resource_type == "knowledge" and not body.lstrip().startswith("#"):
            fh.write(f"# {title}\n\n")
        fh.write(body.rstrip() + "\n")
    try:
        path.chmod(0o600)
    except OSError:
        pass


def upsert_links(conn: sqlite3.Connection, resource_type: str, slug: str, links: list[str]) -> None:
    conn.execute(
        "DELETE FROM knowledge_links WHERE resource_type = ? AND from_slug = ?",
        (resource_type, slug),
    )
    created_at = now_utc()
    conn.executemany(
        """
        INSERT OR IGNORE INTO knowledge_links (from_slug, to_slug, resource_type, created_at)
        VALUES (?, ?, ?, ?)
        """,
        [(slug, link, resource_type, created_at) for link in links],
    )


def capture_text(
    conn: sqlite3.Connection,
    text: str,
    *,
    source: str,
    metadata: dict[str, str],
    export_dir: Path,
) -> tuple[str, str]:
    created_at = now_utc()
    resource_type = "knowledge" if is_knowledge_note(text) else "memory"
    slug = unique_slug(conn, make_slug(text, created_at))
    stage = "seedling"
    links = extract_wikilinks(text)
    metadata_json = json.dumps(metadata, ensure_ascii=False, sort_keys=True)

    if resource_type == "knowledge":
        title = title_from_text(text)
        conn.execute(
            """
            INSERT INTO knowledge
              (slug, title, body, source, stage, created_at, updated_at, metadata_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (slug, title, text, source, stage, created_at, created_at, metadata_json),
        )
    else:
        title = title_from_text(text)
        conn.execute(
            """
            INSERT INTO memory
              (slug, body, source, stage, created_at, updated_at, metadata_json)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (slug, text, source, stage, created_at, created_at, metadata_json),
        )

    upsert_links(conn, resource_type, slug, links)
    conn.execute(
        """
        INSERT INTO sessions (event_type, resource_type, slug, body, created_at, metadata_json)
        VALUES ('capture', ?, ?, ?, ?, ?)
        """,
        (resource_type, slug, text, created_at, metadata_json),
    )
    conn.commit()
    export_markdown(export_dir, resource_type, slug, title, text, source, stage, created_at, metadata)
    return resource_type, slug


def cmd_capture_event(args: argparse.Namespace) -> int:
    payload = sys.stdin.read()
    if not payload.strip():
        return 0
    try:
        data: object = json.loads(payload)
    except json.JSONDecodeError:
        data = payload

    text = extract_text_field(data).strip()
    if not text:
        return 0
    channel_id = extract_first(data, ("channel_id", "channelId"))
    allowed = allowed_channel_ids()
    if allowed and channel_id not in allowed:
        return 0
    if not allowed and os.environ.get("HERMES_MNEMO_CAPTURE_WITHOUT_CHANNEL") != "1":
        return 0

    metadata = {
        "channel_id": channel_id,
        "user_id": extract_first(data, ("user_id", "userId", "id")),
        "message_id": extract_first(data, ("message_id", "messageId")),
    }
    with connect(args.db) as conn:
        resource_type, slug = capture_text(
            conn,
            text,
            source="discord",
            metadata=metadata,
            export_dir=args.export_dir,
        )
    if args.print_slug:
        print(f"{resource_type}\t{slug}")
    return 0


def query_terms(conn: sqlite3.Connection, query: str) -> list[str]:
    terms = [query]
    for row in conn.execute("SELECT synonyms_json FROM knowledge_synonyms WHERE term = ?", (query,)):
        try:
            terms.extend(json.loads(row["synonyms_json"]))
        except json.JSONDecodeError:
            pass
    return [term for term in dict.fromkeys(term.strip() for term in terms) if term]


def search_rows(conn: sqlite3.Connection, query: str, limit: int) -> list[sqlite3.Row]:
    terms = query_terms(conn, query)
    clauses = []
    params: list[str] = []
    for term in terms:
        clauses.append("body LIKE ?")
        params.append(f"%{term}%")
    where = " OR ".join(clauses) or "1 = 1"
    rows = list(
        conn.execute(
            f"""
            SELECT 'memory' AS resource_type, slug, body, source, stage, created_at,
                   last_viewed_at, view_count
            FROM memory
            WHERE {where}
            UNION ALL
            SELECT 'knowledge' AS resource_type, slug, body, source, stage, created_at,
                   last_viewed_at, view_count
            FROM knowledge
            WHERE {where}
            ORDER BY view_count ASC, created_at DESC
            LIMIT ?
            """,
            [*params, *params, limit],
        )
    )
    viewed_at = now_utc()
    for row in rows:
        table = "memory" if row["resource_type"] == "memory" else "knowledge"
        conn.execute(
            f"UPDATE {table} SET view_count = view_count + 1, last_viewed_at = ? WHERE slug = ?",
            (viewed_at, row["slug"]),
        )
    if rows:
        conn.execute(
            """
            INSERT INTO sessions (event_type, body, created_at, metadata_json)
            VALUES ('recall', ?, ?, ?)
            """,
            (query, viewed_at, json.dumps({"hits": len(rows)}, ensure_ascii=False)),
        )
    conn.commit()
    return rows


def snippet(text: str, query: str, width: int = 140) -> str:
    one_line = re.sub(r"\s+", " ", text).strip()
    index = one_line.lower().find(query.lower())
    if index < 0:
        return one_line[:width]
    start = max(0, index - 30)
    return one_line[start : start + width]


def cmd_recall(args: argparse.Namespace) -> int:
    with connect(args.db) as conn:
        rows = search_rows(conn, args.query, args.limit)
    if not rows:
        print("覚えている記憶は見つかりませんでした。")
        return 1 if args.strict else 0
    print("覚えていること:")
    for row in rows:
        links = ", ".join(f"[[{link}]]" for link in extract_wikilinks(row["body"]))
        suffix = f" / 関連: {links}" if links else ""
        print(f"- {snippet(row['body'], args.query)} ({row['resource_type']}:{row['slug']}{suffix})")
    return 0


def cmd_backlinks(args: argparse.Namespace) -> int:
    slug = normalize_slug(args.slug)
    with connect(args.db) as conn:
        rows = conn.execute(
            """
            SELECT resource_type, from_slug
            FROM knowledge_links
            WHERE to_slug = ?
            ORDER BY resource_type, from_slug
            """,
            (slug,),
        ).fetchall()
    if not rows:
        print(f"[[{slug}]] への backlinks はありません。")
        return 0
    print(f"[[{slug}]] backlinks:")
    for row in rows:
        print(f"- {row['resource_type']}:{row['from_slug']}")
    return 0


def existing_slugs(conn: sqlite3.Connection) -> set[str]:
    slugs = {row["slug"] for row in conn.execute("SELECT slug FROM memory")}
    slugs.update(row["slug"] for row in conn.execute("SELECT slug FROM knowledge"))
    return slugs


def cmd_red_links(args: argparse.Namespace) -> int:
    with connect(args.db) as conn:
        known = existing_slugs(conn)
        rows = conn.execute(
            """
            SELECT to_slug, COUNT(*) AS refs
            FROM knowledge_links
            GROUP BY to_slug
            ORDER BY refs DESC, to_slug
            """
        ).fetchall()
    missing = [row for row in rows if row["to_slug"] not in known]
    if not missing:
        print("未作成リンクはありません。")
        return 0
    print("未作成リンク:")
    for row in missing[: args.limit]:
        print(f"- [[{row['to_slug']}]] {row['refs']} refs")
    return 0


def cmd_graph(args: argparse.Namespace) -> int:
    with connect(args.db) as conn:
        rows = conn.execute(
            "SELECT from_slug, to_slug, resource_type FROM knowledge_links ORDER BY from_slug, to_slug"
        ).fetchall()
    if args.format == "mermaid":
        print("flowchart LR")
        if not rows:
            print('  empty["No links yet"]')
        for row in rows:
            print(f"  {normalize_slug(row['from_slug']).replace('-', '_')} --> {normalize_slug(row['to_slug']).replace('-', '_')}")
    else:
        for row in rows:
            print(f"{row['resource_type']}:{row['from_slug']} -> [[{row['to_slug']}]]")
    return 0


def cmd_curator(args: argparse.Namespace) -> int:
    cutoff = dt.datetime.now(dt.UTC) - dt.timedelta(days=args.stale_after_days)
    cutoff_s = cutoff.replace(microsecond=0).isoformat()
    with connect(args.db) as conn:
        stale = conn.execute(
            """
            SELECT 'memory' AS resource_type, slug, created_at, view_count FROM memory
            WHERE stage = 'seedling' AND created_at < ? AND view_count = 0
            UNION ALL
            SELECT 'knowledge' AS resource_type, slug, created_at, view_count FROM knowledge
            WHERE stage = 'seedling' AND created_at < ? AND view_count = 0
            ORDER BY created_at
            LIMIT ?
            """,
            (cutoff_s, cutoff_s, args.limit),
        ).fetchall()
        refs = conn.execute(
            """
            SELECT to_slug, COUNT(*) AS refs
            FROM knowledge_links
            GROUP BY to_slug
            HAVING refs >= ?
            ORDER BY refs DESC, to_slug
            LIMIT ?
            """,
            (args.min_refs, args.limit),
        ).fetchall()
    print("mnemo curator status")
    print(f"- stale seedling: {len(stale)}")
    for row in stale:
        print(f"  - {row['resource_type']}:{row['slug']} created_at={row['created_at']}")
    print(f"- promote candidates by refs >= {args.min_refs}: {len(refs)}")
    for row in refs:
        print(f"  - [[{row['to_slug']}]] {row['refs']} refs")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Hermes mnemo-like local memory")
    parser.add_argument("--db", type=expand_path, default=default_db_path())
    parser.add_argument("--export-dir", type=expand_path, default=default_export_dir())
    sub = parser.add_subparsers(dest="command", required=True)

    capture_event = sub.add_parser("capture-event", help="capture a Discord event from stdin")
    capture_event.add_argument("--print-slug", action="store_true")
    capture_event.set_defaults(func=cmd_capture_event)

    recall = sub.add_parser("recall", help="search saved memory and knowledge")
    recall.add_argument("query")
    recall.add_argument("-n", "--limit", type=int, default=5)
    recall.add_argument("--strict", action="store_true")
    recall.set_defaults(func=cmd_recall)

    backlinks = sub.add_parser("backlinks", help="show backlinks for a wikilink slug")
    backlinks.add_argument("slug")
    backlinks.set_defaults(func=cmd_backlinks)

    red_links = sub.add_parser("red-links", help="show referenced but missing slugs")
    red_links.add_argument("-n", "--limit", type=int, default=20)
    red_links.set_defaults(func=cmd_red_links)

    graph = sub.add_parser("graph", help="show the wikilink graph")
    graph.add_argument("--format", choices=("text", "mermaid"), default="text")
    graph.set_defaults(func=cmd_graph)

    curator = sub.add_parser("curator", help="show stale and promote candidates")
    curator.add_argument("action", choices=("status",))
    curator.add_argument("--stale-after-days", type=int, default=30)
    curator.add_argument("--min-refs", type=int, default=2)
    curator.add_argument("-n", "--limit", type=int, default=20)
    curator.set_defaults(func=cmd_curator)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
