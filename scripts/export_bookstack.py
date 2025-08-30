"""
Export BookStack pages from the DB to local files (Markdown when available, else HTML).

Requirements:
  pip install pymysql pandas

Env vars expected (preferred):
  BS_DB_HOST, BS_DB_PORT, BS_DB_NAME, BS_DB_USER, BS_DB_PASS

Fallbacks (auto-read from repo .env if present):
  DB_DATABASE -> BS_DB_NAME
  DB_USERNAME -> BS_DB_USER
  DB_PASSWORD -> BS_DB_PASS

Notes:
  - Host/port are NOT inferred from docker-compose. If your DB is not exposed
    to the host, either: temporarily publish port 3306 to 127.0.0.1 in your
    compose file, or run this exporter inside a container on the same network.
"""

from __future__ import annotations

import argparse
import os
import re
from pathlib import Path
from typing import Dict, Tuple

import pandas as pd
import pymysql


REPO_ROOT = Path(__file__).resolve().parents[1]
REPO_ENV = REPO_ROOT / ".env"


def _load_repo_env_fallbacks() -> None:
    """Populate BS_DB_* from repo .env if not already set.

    Only maps DB_DATABASE/DB_USERNAME/DB_PASSWORD. Does not set host/port.
    """
    if not REPO_ENV.exists():
        return

    try:
        content = REPO_ENV.read_text(encoding="utf-8")
    except Exception:
        return

    def get_key(key: str) -> str | None:
        pat = re.compile(rf"^{re.escape(key)}=(.*)$", re.M)
        m = pat.search(content)
        if not m:
            return None
        # Strip optional surrounding quotes
        val = m.group(1).strip()
        if (val.startswith("\"") and val.endswith("\"")) or (
            val.startswith("'") and val.endswith("'")
        ):
            val = val[1:-1]
        return val

    if not os.environ.get("BS_DB_NAME"):
        v = get_key("DB_DATABASE")
        if v:
            os.environ["BS_DB_NAME"] = v
    if not os.environ.get("BS_DB_USER"):
        v = get_key("DB_USERNAME")
        if v:
            os.environ["BS_DB_USER"] = v
    if not os.environ.get("BS_DB_PASS"):
        v = get_key("DB_PASSWORD")
        if v:
            os.environ["BS_DB_PASS"] = v


def _safe_name(name: str) -> str:
    """Filesystem-safe name (keeps readability)."""
    name = name.strip().replace("/", "-")
    name = re.sub(r"[^\w\-\s.]", "", name)
    name = re.sub(r"\s+", "_", name)
    return name[:120] or "untitled"


def _pick_content(row: Dict, prefer_markdown: bool = True) -> Tuple[str, str]:
    """
    Decide whether to write Markdown or HTML.

    Returns:
        (content, extension) where extension is 'md' or 'html'.
    """
    md = (row.get("markdown") or "").strip()
    if prefer_markdown and md:
        return md, "md"
    html = (row.get("html") or "").strip()
    return html, "html"


def _connect() -> pymysql.connections.Connection:
    """Connect to MySQL/MariaDB using env vars."""
    missing = []
    for k in ("BS_DB_HOST", "BS_DB_NAME", "BS_DB_USER", "BS_DB_PASS"):
        if not os.environ.get(k):
            missing.append(k)
    if missing:
        raise SystemExit(
            "Missing env: "
            + ", ".join(missing)
            + "\nSet BS_DB_HOST/BS_DB_PORT/BS_DB_NAME/BS_DB_USER/BS_DB_PASS.\n"
            + f"Repo .env loaded for DB name/user/pass: {REPO_ENV if REPO_ENV.exists() else 'not found'}\n"
            + "Hint: If DB isn't exposed on host, publish 3306:3306 to 127.0.0.1 or run inside the compose network."
        )

    return pymysql.connect(
        host=os.environ["BS_DB_HOST"],
        port=int(os.environ.get("BS_DB_PORT", 3306)),
        user=os.environ["BS_DB_USER"],
        password=os.environ["BS_DB_PASS"],
        database=os.environ["BS_DB_NAME"],
        charset="utf8mb4",
        cursorclass=pymysql.cursors.DictCursor,
        read_timeout=30,
        write_timeout=30,
    )


def fetch_pages() -> pd.DataFrame:
    """
    Fetch page rows joined to book/chapter for path building.
    Only non-draft pages are exported.
    """
    sql = """
    SELECT
      p.id, p.name, p.slug, p.book_id, p.chapter_id, p.draft,
      p.html, p.markdown, p.created_at, p.updated_at,
      b.id AS book_id_real, b.name AS book_name, b.slug AS book_slug,
      c.id AS chapter_id_real, c.name AS chapter_name, c.slug AS chapter_slug
    FROM pages p
    LEFT JOIN chapters c ON p.chapter_id = c.id
    LEFT JOIN books b ON COALESCE(c.book_id, p.book_id) = b.id
    WHERE p.draft = 0
    ORDER BY b.name, c.name, p.name, p.id
    """
    with _connect() as conn, conn.cursor() as cur:
        cur.execute(sql)
        rows = cur.fetchall()
    return pd.DataFrame(rows)


def export_pages(out_dir: Path, prefer_markdown: bool = True) -> pd.DataFrame:
    """
    Export each page to a file under:
      out_dir/{book}/{optional_chapter}/{id}_{name}.{md|html}

    Returns:
        DataFrame index of exported files & metadata.
    """
    out_dir.mkdir(parents=True, exist_ok=True)
    df = fetch_pages()
    exports = []

    for _, row in df.iterrows():
        book_dir = _safe_name(row.get("book_name") or "No_Book")
        if row.get("chapter_name"):
            subdir = out_dir / book_dir / _safe_name(row["chapter_name"])
        else:
            subdir = out_dir / book_dir
        subdir.mkdir(parents=True, exist_ok=True)

        content, ext = _pick_content(row, prefer_markdown=prefer_markdown)
        fname = f"{int(row['id']):06d}_{_safe_name(row['name'] or '')}.{ext}"
        fpath = subdir / fname
        fpath.write_text(content, encoding="utf-8")

        exports.append(
            {
                "page_id": int(row["id"]),
                "book": row.get("book_name"),
                "chapter": row.get("chapter_name"),
                "name": row.get("name"),
                "slug": row.get("slug"),
                "path": str(fpath),
                "ext": ext,
                "updated_at": row.get("updated_at"),
            }
        )

    out_idx = pd.DataFrame(exports)
    out_idx.to_csv(out_dir / "_index.csv", index=False)
    return out_idx


# ---------- Simple tests (no DB needed) ----------
def _test_safe_name():
    assert _safe_name("A/B:C*D?") == "ABCD"
    assert _safe_name("   Hello  World  ") == "Hello_World"


def _test_pick_content():
    assert _pick_content({"markdown": "x", "html": "y"}) == ("x", "md")
    assert _pick_content({"markdown": "", "html": "y"}) == ("y", "html")


def main() -> None:
    parser = argparse.ArgumentParser(description="Export BookStack pages to files")
    parser.add_argument(
        "-o",
        "--out",
        type=Path,
        default=Path("bookstack_export"),
        help="Output directory (default: ./bookstack_export)",
    )
    parser.add_argument(
        "--html",
        action="store_true",
        help="Prefer HTML over Markdown when both are present",
    )
    args = parser.parse_args()

    # Try to populate DB_NAME/USER/PASS from repo .env when not set
    _load_repo_env_fallbacks()

    prefer_md = not args.html
    idx = export_pages(args.out, prefer_markdown=prefer_md)
    print(f"Exported {len(idx)} pages to: {args.out.resolve()}")


if __name__ == "__main__":
    # Run quick unit tests for helpers.
    _test_safe_name()
    _test_pick_content()
    main()

