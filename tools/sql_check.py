#!/usr/bin/env python3
"""Run SQL behavior tests and pgTAP, failing on TAP failures as well as SQL errors."""
import argparse
import os
from pathlib import Path
import subprocess
root=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser();parser.add_argument('--bootstrap',action='store_true');args=parser.parse_args()
psql=os.environ.get('PSQL','psql')
files=[]
if args.bootstrap: files.extend(['infra/supabase/tests/local_auth.sql','infra/supabase/migrations/202609230001_platform.sql','infra/supabase/migrations/202609230002_phase3.sql'])
files.extend(['infra/supabase/tests/security.sql','infra/supabase/tests/phase3.sql','infra/supabase/tests/rls.pgtap.sql'])
for path in files:
    result=subprocess.run([psql,'-X','-A','-t','-v','ON_ERROR_STOP=1','-f',str(root/path)],text=True,capture_output=True)
    print(result.stdout,end='')
    if result.returncode or any(line.startswith('not ok') for line in result.stdout.splitlines()):
        raise SystemExit(result.stderr or f'TAP failure in {path}')
print('Database behavior and pgTAP checks passed')
