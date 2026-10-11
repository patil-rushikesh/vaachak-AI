#!/usr/bin/env python3
"""Run reproducible local checks. FLUTTER may name an SDK outside PATH."""
import os
from pathlib import Path
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
flutter = os.environ.get('FLUTTER') or shutil.which('flutter')
if not flutter:
    raise SystemExit('Set FLUTTER to the path of the Flutter SDK executable.')
dart = str(Path(flutter).resolve().with_name('dart'))
def run(args, cwd=root):
    subprocess.run(args, cwd=cwd, check=True)
run([flutter, 'pub', 'get', '--enforce-lockfile'])
run([dart, 'format', '--output=none', '--set-exit-if-changed', 'packages'])
run([flutter, 'analyze', '--no-pub'])
for package in ['vaachak_engine', 'vaachak_content', 'vaachak_store', 'vaachak_packs', 'vaachak_sync']:
    run([dart, 'test'], root / 'packages' / package)
for package in ['vaachak_explain', 'vaachak_speech']:
    run([flutter, 'test', '--no-pub'], root / 'packages' / package)
run([sys.executable, '-m', 'unittest', 'discover', '-s', 'tools/content_pipeline', '-v'])
run([sys.executable, 'tools/content_pipeline/pipeline.py', 'validate', 'content'])
run([sys.executable, '-m', 'pytest', 'classroom_web/tests', '-q'])
