#!/usr/bin/env python3
"""Start an isolated, disposable PostgreSQL/PostgREST development deployment.
Only synthetic users are provisioned. Credentials stay in a mode-0600 file
outside the repository. This does not emulate RPCs: PostgREST executes migrations.
"""
import argparse,base64,hashlib,hmac,json,os,secrets,shutil,subprocess,time
from pathlib import Path
root=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser();parser.add_argument('action',choices=['start','stop']);args=parser.parse_args()
state=Path.home()/'.local/share/vaachak/phase3-local';state.mkdir(parents=True,exist_ok=True);state.chmod(0o700)
pg=Path(os.environ.get('PG_BIN','/opt/homebrew/opt/postgresql@16/bin'))
def run(cmd,**kw):return subprocess.run([str(x) for x in cmd],check=True,**kw)
if args.action=='stop':
 for name in ['gateway','postgrest']:
  p=state/f'{name}.pid'
  if p.exists():
   try:os.kill(int(p.read_text()),15)
   except ProcessLookupError:pass
   p.unlink()
 run([pg/'pg_ctl','-D',state/'db','stop','-m','fast'])
 raise SystemExit()
if not (state/'db/PG_VERSION').exists():run([pg/'initdb','-D',state/'db','-A','trust','--no-locale'],stdout=subprocess.DEVNULL)
if not (state/'db/postmaster.pid').exists():run([pg/'pg_ctl','-D',state/'db','-l',state/'postgres.log','-o',f'-p 55432 -h 127.0.0.1 -k {state}','start'],stdout=subprocess.DEVNULL)
env={**os.environ,'PGHOST':'127.0.0.1','PGPORT':'55432','PGDATABASE':'postgres'}
def sql(query):return run([pg/'psql','-X','-v','ON_ERROR_STOP=1','-At','-c',query],env=env,capture_output=True,text=True).stdout.strip()
if sql("SELECT count(*) FROM pg_namespace WHERE nspname='dev'")=='0':
 for f in ['tests/local_auth.sql','migrations/202609230001_platform.sql','migrations/202609230002_phase3.sql']:
  run([pg/'psql','-X','-v','ON_ERROR_STOP=1','-f',root/'infra/supabase'/f],env=env,stdout=subprocess.DEVNULL)
 sql("CREATE ROLE vaachak_rest LOGIN NOINHERIT; GRANT anon,authenticated TO vaachak_rest")
 sql("CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT coalesce(nullif(current_setting('request.jwt.claim.sub',true),''),nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'sub')::uuid $$")
 sql("""INSERT INTO auth.users VALUES ('10000000-0000-0000-0000-000000000011'),('10000000-0000-0000-0000-000000000012'),('10000000-0000-0000-0000-000000000013');
 INSERT INTO dev.orgs(id,name) VALUES('20000000-0000-0000-0000-000000000011','Local test school');
 INSERT INTO dev.teachers VALUES('10000000-0000-0000-0000-000000000011','20000000-0000-0000-0000-000000000011','Test teacher'),('10000000-0000-0000-0000-000000000013','20000000-0000-0000-0000-000000000011','Other teacher');
 INSERT INTO dev.classes(id,org_id,name) VALUES('30000000-0000-0000-0000-000000000011','20000000-0000-0000-0000-000000000011','Local class');
 INSERT INTO dev.teacher_assignments(class_id,teacher_id) VALUES('30000000-0000-0000-0000-000000000011','10000000-0000-0000-0000-000000000011');""")
secret_file=state/'jwt.secret'
if not secret_file.exists():secret_file.write_text(secrets.token_hex(32));secret_file.chmod(0o600)
secret=secret_file.read_text()
def b64(data):return base64.urlsafe_b64encode(data).rstrip(b'=')
def token(user):
 body=b64(b'{"alg":"HS256","typ":"JWT"}')+b'.'+b64(json.dumps({'sub':user,'role':'authenticated','exp':int(time.time())+86400}).encode())
 return (body+b'.'+b64(hmac.new(secret.encode(),body,hashlib.sha256).digest())).decode()
config={'url':'http://127.0.0.1:55434','classId':'30000000-0000-0000-0000-000000000011','teacherId':'10000000-0000-0000-0000-000000000011','teacherToken':token('10000000-0000-0000-0000-000000000011'),'learnerToken':token('10000000-0000-0000-0000-000000000012'),'outsiderToken':token('10000000-0000-0000-0000-000000000013')}
(state/'test-config.json').write_text(json.dumps(config));(state/'test-config.json').chmod(0o600)
rest=shutil.which('postgrest')
if not rest:raise SystemExit('Install PostgREST first (brew install postgrest).')
for name,cmd,extra in [('postgrest',[rest],{'PGRST_DB_URI':'postgres://vaachak_rest@127.0.0.1:55432/postgres','PGRST_DB_SCHEMAS':'dev,qa,prod','PGRST_DB_ANON_ROLE':'anon','PGRST_JWT_SECRET':secret,'PGRST_SERVER_HOST':'127.0.0.1','PGRST_SERVER_PORT':'55433'}),('gateway',['python3',str(root/'tools/local_rest_gateway.py')],{})]:
 pid=state/f'{name}.pid'
 if pid.exists():
  try:os.kill(int(pid.read_text()),0);continue
  except ProcessLookupError:pid.unlink()
 p=subprocess.Popen(cmd,env={**os.environ,**extra},stdout=(state/f'{name}.log').open('a'),stderr=subprocess.STDOUT,start_new_session=True)
 pid.write_text(str(p.pid))
print(f'Local REST backend: {config["url"]}; synthetic test credentials: {state / "test-config.json"}')
