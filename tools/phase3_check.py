#!/usr/bin/env python3
"""Run real local Phase 3 API/SQL checks, optionally Android UI integration.
The local server must be started with tools/local_phase3.py start first.
"""
import argparse,json,os,subprocess
from pathlib import Path
parser=argparse.ArgumentParser();parser.add_argument('--android',action='store_true');args=parser.parse_args()
root=Path(__file__).resolve().parents[1];state=Path.home()/'.local/share/vaachak/phase3-local'
flutter=os.environ.get('FLUTTER',str(Path.home()/'.local/share/vaachak/flutter/bin/flutter'))
config=json.loads((state/'test-config.json').read_text())
pg=os.environ.get('PSQL','/opt/homebrew/opt/postgresql@16/bin/psql')
env={**os.environ,'PGHOST':'127.0.0.1','PGPORT':'55432','PGDATABASE':'postgres','PSQL':pg}
subprocess.run(['python3','tools/sql_check.py'],cwd=root,env=env,check=True)
# Reset only the synthetic fixture account's join-rate counter between runs.
subprocess.run([pg,'-X','-v','ON_ERROR_STOP=1','-c',"DELETE FROM dev.join_attempts WHERE user_id='10000000-0000-0000-0000-000000000012'"],env=env,check=True,stdout=subprocess.DEVNULL)
app=root/'apps/vaachak_app'
subprocess.run([flutter,'test','--no-pub','test/real_school_test.dart'],cwd=app,env={**os.environ,'PHASE3_CONFIG':str(state/'test-config.json')},check=True)
if args.android:
 adb=Path(os.environ.get('ANDROID_HOME',str(Path.home()/'Library/Android/sdk')))/'platform-tools/adb'
 subprocess.run([str(adb),'reverse','tcp:55434','tcp:55434'],check=True)
 for target,role in [('phase3_school_test.dart',None),('phase3_teacher_test.dart','teacher'),('phase3_learner_test.dart','learner'),('phase3_qr_test.dart',None)]:
  defines={'PHASE3_TEST_CONFIG':json.dumps(config)}
  if role:defines.update(SUPABASE_URL=config['url'],SUPABASE_ANON_KEY='local-test',LOCAL_TEST_ACCESS_TOKEN=config[f'{role}Token'],VAACHAK_ENV='dev')
  path=state/f'check-{role or "api"}.json';path.write_text(json.dumps(defines));path.chmod(0o600)
  subprocess.run([flutter,'test',f'integration_test/{target}','-d','emulator-5554',f'--dart-define-from-file={path}'],cwd=app,check=True)
print('Phase 3 real local backend checks passed.')
