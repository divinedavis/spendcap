#!/usr/bin/env python3
"""Apply a migration file to the Spendcap Supabase project.

The Supabase CLI is not wired up here, so migrations go through the management
API's SQL endpoint. Two gotchas it exists to encode:

  * the endpoint 403s behind Cloudflare unless the User-Agent is non-default
  * PostgREST keeps serving the old schema until it is told to reload, so every
    run ends with `notify pgrst, 'reload schema'`

The PAT comes from the `supabase-pat-clockin` keychain entry — it is an account
token shared across projects, so it is never written to a file here.

Usage:
    python3 scripts/apply_migration.py supabase/migrations/0010_trips.sql
    python3 scripts/apply_migration.py --verify   # list trip objects only
"""
from __future__ import annotations

import argparse
import pathlib
import subprocess
import sys

import requests

PROJECT_REF = "gmzzbslcsswqjjswoaen"
ENDPOINT = f"https://api.supabase.com/v1/projects/{PROJECT_REF}/database/query"
# Cloudflare rejects the default python-requests UA on this endpoint.
HEADERS_UA = "spendcap-migrator/1.0"

VERIFY_SQL = """
select table_name as object
  from information_schema.tables
 where table_schema = 'public' and table_name like 'trip%'
union all
select routine_name
  from information_schema.routines
 where routine_schema = 'public' and routine_name like 'trip%'
 order by object;
"""


def pat() -> str:
    result = subprocess.run(
        ["security", "find-generic-password", "-s", "supabase-pat-clockin", "-w"],
        capture_output=True, text=True,
    )
    if result.returncode != 0 or not result.stdout.strip():
        raise SystemExit("could not read supabase-pat-clockin from the keychain")
    return result.stdout.strip()


def run_sql(sql: str, token: str) -> list:
    response = requests.post(
        ENDPOINT,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "User-Agent": HEADERS_UA,
        },
        json={"query": sql},
        timeout=120,
    )
    if not response.ok:
        raise SystemExit(f"SQL failed: {response.status_code} {response.text[:600]}")
    try:
        return response.json()
    except ValueError:
        return []


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("migration", nargs="?", help="path to a .sql file")
    parser.add_argument("--verify", action="store_true", help="list trip objects and exit")
    args = parser.parse_args()

    token = pat()

    if args.verify:
        for row in run_sql(VERIFY_SQL, token):
            print(" ", row.get("object"))
        return 0

    if not args.migration:
        parser.error("pass a migration path or --verify")
    path = pathlib.Path(args.migration)
    if not path.exists():
        raise SystemExit(f"missing {path}")

    print(f"==> applying {path.name} ({len(path.read_text())} bytes)")
    run_sql(path.read_text(), token)
    run_sql("notify pgrst, 'reload schema';", token)
    print("==> applied, PostgREST reloaded")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
