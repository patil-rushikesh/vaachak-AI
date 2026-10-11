"""Small DB-API adapter for Vaachak's existing parameterized repository queries.

Read queries run in autocommit, as in SQLite. Writes stay in a transaction until
commit/rollback. Explicit critical sections use a transaction advisory lock so
submission claims and job leasing keep their existing serialization semantics.
This is deliberately not a general-purpose SQLite SQL translator.
"""
import re
import os
from urllib.parse import urlsplit, parse_qs
from pathlib import Path

import psycopg
from psycopg.pq import TransactionStatus

IDENTITY_TABLES = {
    'users', 'classes', 'recordings', 'assignments', 'attempts', 'courses',
    'units', 'lessons', 'insight_actions', 'privacy_events', 'feedback_reports',
}
CRITICAL_SECTION_LOCK = 862314072
MIGRATION_LOCK = 862314073


class Row(dict):
    def __getitem__(self, key):
        return tuple(self.values())[key] if isinstance(key, (int, slice)) else super().__getitem__(key)


def row_factory(cursor):
    names = [c.name for c in cursor.description] if cursor.description else []
    return lambda values: Row(zip(names, values))


def translate(sql):
    # Tokenize quoted strings/identifiers so '?' and '%' in literal data remain literal.
    parts = re.split(r"('(?:''|[^'])*'|\"(?:\"\"|[^\"])*\")", sql)
    for i in range(0, len(parts), 2):
        part = re.sub(r'\bwindow\b', '"window"', parts[i], flags=re.I)
        part = re.sub(r'datetime\(([^()]+)\)', r'CAST(\1 AS timestamptz)', part, flags=re.I)
        parts[i] = part.replace('?', '%s')
    return ''.join(parts)


class Cursor:
    def __init__(self, cursor, lastrowid=None):
        self.cursor, self.lastrowid = cursor, lastrowid
        self.rowcount = cursor.rowcount

    def fetchone(self):
        return self.cursor.fetchone()

    def fetchall(self):
        return self.cursor.fetchall()

    def __iter__(self):
        return iter(self.cursor)


class Connection:
    dialect = 'postgres'

    def __init__(self, url):
        self.raw = psycopg.connect(url, autocommit=True, row_factory=row_factory,
                                   connect_timeout=15, prepare_threshold=None)
        self.total_changes = 0

    def execute(self, sql, parameters=()):
        normalized = sql.strip().rstrip(';')
        if normalized.upper() == 'BEGIN IMMEDIATE':
            if self.raw.info.transaction_status != TransactionStatus.IDLE:
                raise psycopg.ProgrammingError('Nested critical section')
            self.raw.execute('BEGIN')
            self.raw.execute("SET LOCAL lock_timeout = '15s'")
            return Cursor(self.raw.execute('SELECT pg_advisory_xact_lock(%s)', (CRITICAL_SECTION_LOCK,)))
        write = bool(re.match(r'^(INSERT|UPDATE|DELETE)\b', normalized, re.I))
        if write and self.raw.info.transaction_status == TransactionStatus.IDLE:
            self.raw.execute('BEGIN')
        identity = re.match(r'^INSERT INTO (\w+)\b', normalized, re.I)
        returning = identity and identity[1].lower() in IDENTITY_TABLES and 'RETURNING' not in normalized.upper()
        statement = translate(normalized)
        if returning:
            statement += ' RETURNING id'
        params = tuple(int(p) if isinstance(p, bool) else p for p in parameters)
        # Psycopg requires literal '%' to be escaped only when binding parameters.
        if params:
            statement = re.sub(r'%(?!s\b)', '%%', statement)
        cur = self.raw.execute(statement, params or None)
        self.total_changes += max(cur.rowcount, 0) if write else 0
        inserted = cur.fetchone()['id'] if returning and cur.rowcount else None
        return Cursor(cur, inserted)

    def commit(self):
        self.raw.commit()

    def rollback(self):
        self.raw.rollback()

    def close(self):
        self.raw.close()

    def __enter__(self):
        return self

    def __exit__(self, kind, value, traceback):
        try:
            self.rollback() if kind else self.commit()
        finally:
            self.close()


def validate_url(url):
    parsed = urlsplit(url)
    if parsed.scheme not in ("postgresql", "postgres") or not parsed.hostname:
        raise ValueError("DATABASE_URL must be a Postgres connection URL")
    if os.getenv("VAACHAK_ENV") == "production" and parse_qs(parsed.query).get("sslmode", [""])[0] not in ("require", "verify-ca", "verify-full"):
        raise ValueError("Production Postgres requires TLS via sslmode")


def init(url):
    validate_url(url)
    with Connection(url) as conn:
        # Transaction-scoped locks work with Neon's transaction connection pooler.
        conn.raw.execute('BEGIN')
        conn.raw.execute('SELECT pg_advisory_xact_lock(%s)', (MIGRATION_LOCK,))
        exists = conn.raw.execute("SELECT to_regclass('public.schema_migrations')").fetchone()[0]
        if not exists:
            conn.raw.execute(Path(__file__).with_name('postgres_schema.sql').read_text())
        else:
            version = conn.execute('SELECT max(version) FROM schema_migrations').fetchone()[0]
            if version != 7:
                raise RuntimeError('Unsupported Postgres schema version; run the matching release migration.')
        from knowledge_seed import install
        install(conn)
