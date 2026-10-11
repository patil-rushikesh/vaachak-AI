"""Build an ordered, repeatable local Postman run covering every classroom endpoint."""
import argparse
import json
import re
import wave
from pathlib import Path
R=Path(__file__).resolve().parents[1]
out=R/'postman'
fixture=out/'fixtures'/'silence.wav'
fixture.parent.mkdir(exist_ok=True)
with wave.open(str(fixture),'wb') as w:
 w.setnchannels(1);w.setsampwidth(2);w.setframerate(16000);w.writeframes(b'\0\0'*16000)
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument("--audio-file", type=Path, help="Existing fixture inside the Postman working directory for desktop runs")
args=parser.parse_args()
upload_fixture=args.audio_file.resolve() if args.audio_file else fixture
if not upload_fixture.is_file():
 raise SystemExit(f"Audio fixture missing: {upload_fixture}")
items=[]
covered=set()
def add(method,path,role='teacher',body=None,form=None,capture=None,checks=(),status=200,label=None):
 covered.add((method.lower(),re.sub(r'\{\{(\w+)\}\}',r'{\1}',path)))
 req={'method':method,'url':'{{base_url}}'+path,'header':[],'auth':{'type':'noauth'} if role is None else {'type':'bearer','bearer':[{'key':'token','value':'{{'+role+'_token}}','type':'string'}]}}
 if body is not None:
  req['header']=[{'key':'Content-Type','value':'application/json'}]
  raw=json.dumps(body)
  raw=re.sub(r'"(\{\{(?:student_id|course_id|assignment_id)\}\})"',r'\1',raw)
  req['body']={'mode':'raw','raw':raw,'options':{'raw':{'language':'json'}}}
 if form is not None:
  fields=[]
  for key,value in form.items():
   fields.append({'key':key,'type':'file','src':str(upload_fixture),'contentType':'audio/wav'} if key in ('file','audio') else {'key':key,'value':str(value),'type':'text'})
  req['body']={'mode':'formdata','formdata':fields}
 tests=[f'pm.test("HTTP {status}", () => pm.response.to.have.status({status}));']
 if capture:
  tests+=['if (pm.response.code === 200) { const data=pm.response.json();']
  for key,field in capture.items():tests.append(f'pm.collectionVariables.set("{key}", String(data.{field}));')
  tests+=['}']
 tests+=list(checks)
 items.append({'name':f'{len(items)+1:02d} '+(label or method+' '+path),'request':req,'event':[{'listen':'test','script':{'type':'text/javascript','exec':tests}}]})
add('GET','/api/health',None,checks=['pm.test("Database is healthy", () => pm.expect(pm.response.json().ok).to.eql(true));','pm.collectionVariables.set("ai_configured", String(pm.response.json().ai));'])
for role,api_role in [('teacher','teacher'),('student','student')]:
 add('POST','/api/auth/register',None,{'name':'Smoke '+role,'email':role+'-{{run_id}}@example.test','password':'local-test-password-123','role':api_role},capture={role+'_token':'token',**({'student_id':'user.id'} if role=='student' else {})},label='Register '+role)
add('POST','/api/auth/login',None,{'email':'teacher-{{run_id}}@example.test','password':'local-test-password-123'},capture={'teacher_token':'token'})
add('GET','/api/me',checks=['pm.test("Teacher role", () => pm.expect(pm.response.json().role).to.eql("teacher"));'])
add('POST','/api/classes',body={'name':'Smoke class {{run_id}}','standard':'5','language':'en'},capture={'class_id':'id','class_code':'code'})
add('POST','/api/classes/join','student',{'code':'{{class_code}}'})
add('GET','/api/classes')
add('GET','/api/classes/{{class_id}}',checks=['pm.test("Student joined", () => pm.expect(pm.response.json().roster.some(x => String(x.id) === pm.collectionVariables.get("student_id"))).to.eql(true));'])
add('POST','/api/classes/{{class_id}}/code',capture={'class_code':'code'})
add('POST','/api/recordings',form={'title':'Synthetic silence fixture','duration_ms':1000,'file':True},capture={'rec_id':'id'})
add('GET','/api/recordings')
add('GET','/api/recordings/{{rec_id}}/audio',checks=['pm.test("WAV content type", () => pm.expect(pm.response.headers.get("Content-Type")).to.include("audio/wav"));'])
read={'kind':'read','text':'Hello, how are you?'}
add('POST','/api/classes/{{class_id}}/assignments',body={'title':'Smoke assignment','items':[read]},capture={'assignment_id':'id'})
add('GET','/api/classes/{{class_id}}/assignments','student')
add('GET','/api/assignments/{{assignment_id}}','student')
add('GET','/api/catalog','student')
add('GET','/api/sets/{{set_id}}','student')
add('POST','/api/attempts','student',form={'item_index':0,'assignment_id':'{{assignment_id}}','transcript':'Hello, how are you?','audio':True,'client_uuid':'{{run_id}}'},capture={'attempt_id':'id'})
add('GET','/api/attempts/{{attempt_id}}/audio','student',checks=['pm.test("Attempt audio", () => pm.expect(pm.response.headers.get("Content-Type")).to.include("audio/wav"));'])
add('GET','/api/me/stats','student',checks=['pm.test("Attempt recorded", () => pm.expect(pm.response.json().attempts).to.be.above(0));'])
add('GET','/api/classes/{{class_id}}/performance')
add('GET','/api/classes/{{class_id}}/students/{{student_id}}')
add('GET','/api/classes/{{class_id}}/attention')
add('POST','/api/classes/{{class_id}}/attention/dismiss',body={'student_id':'{{student_id}}','reason':'smoke-test'})
add('GET','/api/classes/{{class_id}}/skill-grid')
add('POST','/api/ai/items',body={'topic':'Greetings','count':2,'kinds':['read'],'level':'A1'},label='AI drafting (requires configured provider)')
items[-1]['event'][0]['script']['exec']=['const configured=pm.collectionVariables.get("ai_configured")==="true";','pm.test(configured ? "AI returns generated items" : "AI correctly reports missing configuration (503)", () => pm.response.to.have.status(configured ? 200 : 503));','if (configured) pm.test("Generated items", () => pm.expect(pm.response.json().items.length).to.be.above(0));']
add('POST','/api/courses',body={'title':'Smoke course {{run_id}}','visibility':'public','sequential':False},capture={'course_id':'id'})
add('GET','/api/courses')
add('GET','/api/courses/{{course_id}}')
add('PATCH','/api/courses/{{course_id}}',body={'title':'Updated smoke course'})
add('POST','/api/courses/{{course_id}}/units',body={'title':'Unit one'},capture={'unit_id':'id'})
add('POST','/api/courses/{{course_id}}/units',body={'title':'Unit two'},capture={'other_unit_id':'id'})
add('PATCH','/api/units/{{unit_id}}',body={'title':'Updated unit'})
add('POST','/api/units/{{unit_id}}/move',body={'direction':'down'})
lesson={'title':'Greetings','intro':'Read aloud','items':[read]}
add('POST','/api/units/{{unit_id}}/lessons',body=lesson,capture={'lesson_id':'id'})
add('POST','/api/units/{{unit_id}}/lessons',body={**lesson,'title':'Second lesson'},capture={'other_lesson_id':'id'})
add('PUT','/api/lessons/{{lesson_id}}',body={**lesson,'title':'Updated greetings'})
add('POST','/api/lessons/{{lesson_id}}/move',body={'direction':'down'})
add('POST','/api/courses/{{course_id}}/publish',body={'published':True})
add('GET','/api/lessons/{{lesson_id}}','student')
add('POST','/api/courses/{{course_id}}/enroll','student')
add('POST','/api/classes/{{class_id}}/courses',body={'course_id':'{{course_id}}'})
add('GET','/api/classes/{{class_id}}/courses','student')
add('POST','/api/attempts','student',form={'item_index':0,'lesson_id':'{{lesson_id}}','transcript':'Hello, how are you?'})
add('GET','/api/courses/{{course_id}}/progress',checks=['pm.test("Learner progress exists", () => pm.expect(pm.response.json().learners.length).to.be.above(0));'])
add('GET','/api/me/review','student')
# Negative access and validation cases, before cleanup.
add('POST','/api/classes','student',{'name':'Forbidden'},status=403,label='Student cannot create classes')
add('GET','/api/me',None,status=401,label='Anonymous access rejected')
add('POST','/api/attempts','student',form={'item_index':0,'lesson_id':'{{lesson_id}}','assignment_id':'{{assignment_id}}','transcript':'Hello'},status=422,label='Ambiguous attempt source rejected')
add('GET','/api/ready',None)
add('GET','/api/me/preferences','student')
add('PATCH','/api/me/preferences','student',body={'timezone':'Asia/Kolkata','language':'en','research_consent':False})
add('GET','/api/me/attempts','student')
add('GET','/api/attempts/{{attempt_id}}','student')
add('GET','/api/me/submissions/{{run_id}}','student')
# Route inventory uses client_uuid, while this run uses its UUID variable.
covered.discard(('get','/api/me/submissions/{run_id}'))
covered.add(('get','/api/me/submissions/{client_uuid}'))
add('PATCH','/api/attempts/{{attempt_id}}/dispute','student',body={'disputed':True})
add('PATCH','/api/attempts/{{attempt_id}}/dispute','student',body={'disputed':False})
add('GET','/api/me/recommendations','student')
add('GET','/api/me/export','student')
add('POST','/api/classes/{{class_id}}/attention/actions',body={'student_id':'{{student_id}}','reason':'never_started','status':'resolved'})
add('GET','/api/classes/{{class_id}}/attention/actions')
add('PATCH','/api/assignments/{{assignment_id}}',body={'title':'Updated smoke assignment','due_at':'2026-12-01T10:00:00Z'})
for resource,key in [('classes','class_id'),('courses','course_id'),('lessons','lesson_id'),('assignments','assignment_id')]:
 for archived in (True,False):
  add('PATCH','/api/'+resource+'/{{'+key+'}}/archive',body={'archived':archived})
add('DELETE','/api/recordings/{{rec_id}}')
add('POST','/api/auth/reset-password',None,body={'token':'invalid-smoke-reset-token','new_password':'new-test-password'},status=400)
add('DELETE','/api/courses/{{course_id}}/enroll','student')
add('DELETE','/api/classes/{{class_id}}/courses/{{course_id}}')
add('DELETE','/api/lessons/{{lesson_id}}',status=409)
add('DELETE','/api/units/{{unit_id}}',status=409)
add('DELETE','/api/courses/{{course_id}}',status=409)
add('DELETE','/api/assignments/{{assignment_id}}',status=409)
add('DELETE','/api/classes/{{class_id}}/students/{{student_id}}')
add('POST','/api/auth/logout','student')
add('GET','/api/me','student',status=401,label='Logged-out token rejected')
add('POST','/api/auth/login',None,{'email':'student-{{run_id}}@example.test','password':'local-test-password-123'},capture={'student_token':'token'})
add('POST','/api/me/password','student',body={'current_password':'local-test-password-123','new_password':'updated-test-password-123'})
add('GET','/api/me','student',status=401,label='Password change revoked sessions')
add('POST','/api/auth/login',None,{'email':'student-{{run_id}}@example.test','password':'updated-test-password-123'},capture={'student_token':'token'})
add('DELETE','/api/me','student',body={'password':'updated-test-password-123'})
add('POST','/api/auth/logout')
expected={(m,p) for p,methods in json.loads((out/'openapi.json').read_text())['paths'].items() for m in methods}
assert expected==covered,(expected-covered,covered-expected)
collection={'info':{'name':'VaachakAI Local Endpoint Tests','schema':'https://schema.getpostman.com/json/collection/v2.1.0/collection.json','description':'Ordered workflow covering all current API operations, including intentional history-deletion guards and invalid reset-token behavior. Creates synthetic users/content; deletes the synthetic learner and its attempts. Teacher and authored content remain. Run only against an isolated test server. Silence WAV verifies upload/download, not speech recognition. AI 503 is expected without a provider key; this does not validate live AI generation. Run against the local development server only.'},'variable':[{'key':'base_url','value':'http://localhost:8000'},{'key':'set_id','value':'en-present-agreement'}], 'item':items}
items[0]['event'].insert(0,{'listen':'prerequest','script':{'type':'text/javascript','exec':['pm.collectionVariables.set("run_id", pm.variables.replaceIn("{{$guid}}"));']}})
(out/'VaachakAI.local-tests.postman_collection.json').write_text(json.dumps(collection,indent=2)+'\n')
print(f'{len(items)} requests covering {len(expected)} endpoints')
