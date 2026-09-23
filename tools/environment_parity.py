#!/usr/bin/env python3
"""Read-only QA/production schema parity check. Never copies learner data."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess


def normalize(dump, schema):
    # pg_dump emits a random psql restriction key and version-specific banners.
    lines = []
    for line in dump.splitlines():
        if line.startswith('--') or line.startswith(('\\restrict ', '\\unrestrict ')):
            continue
        line = re.sub(rf'\b{re.escape(schema)}\b', 'environment', line)
        if line.strip():
            lines.append(line.rstrip())
    return '\n'.join(lines) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pg-dump', default=os.environ.get('PG_DUMP', 'pg_dump'))
    parser.add_argument('--output', type=Path, default=Path('build/verification/environment-parity.json'))
    args = parser.parse_args()
    # Connection comes from libpq environment/service config; no password arguments.
    snapshots = {}
    for schema in ('qa', 'prod'):
        result = subprocess.run([args.pg_dump, '--schema-only', '--no-owner', '--schema', schema],
                                capture_output=True, text=True, check=True)
        if 'CREATE TABLE' not in result.stdout or 'CREATE POLICY' not in result.stdout:
            raise SystemExit(f'{schema}: schema or RLS policies missing')
        snapshots[schema] = normalize(result.stdout, schema)
    report = {'identical': snapshots['qa'] == snapshots['prod'],
              'scope': 'DDL, functions, constraints, policies, grants and indexes; excludes application data and shared Auth configuration',
              'hashes': {s: hashlib.sha256(v.encode()).hexdigest() for s,v in snapshots.items()}}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2)+'\n')
    if not report['identical']:
        import difflib
        diff=''.join(difflib.unified_diff(snapshots['qa'].splitlines(True),snapshots['prod'].splitlines(True),fromfile='qa',tofile='prod'))
        args.output.with_suffix('.diff').write_text(diff)
    print(json.dumps(report, indent=2))
    return 0 if report['identical'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
