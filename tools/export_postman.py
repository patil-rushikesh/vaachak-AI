#!/usr/bin/env python3
"""Export the classroom FastAPI routes without starting the server or touching its database."""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'classroom_web/server'))
from main import app

spec = app.openapi()
if '--schema-only' in sys.argv:
    print(json.dumps(spec))
    sys.exit(0)
variables = {
    'base_url': 'http://localhost:8000', 'token': '',
    'name': 'Postman Teacher', 'email': 'teacher@example.test',
    'password': 'change-this-test-password', 'role': 'teacher',
    'class_id': '', 'class_code': '', 'student_id': '', 'rec_id': '',
    'client_uuid': '', 'assignment_id': '', 'set_id': 'en-present-agreement', 'attempt_id': '',
    'course_id': '', 'unit_id': '', 'lesson_id': '',
    'knowledge_id': '', 'knowledge_version': 1,
}
examples = {
    'Register': {'name': '{{name}}', 'email': '{{email}}', 'password': '{{password}}', 'role': '{{role}}'},
    'Login': {'email': '{{email}}', 'password': '{{password}}'},
    'ClassIn': {'name': 'English Practice', 'standard': '5', 'section': 'A', 'language': 'en', 'academic_year': '2026-27'},
    'JoinIn': {'code': '{{class_code}}'},
    'AssignmentIn': {'title': 'Present agreement practice', 'set_id': '{{set_id}}'},
    'DismissIn': {'student_id': '{{student_id}}', 'reason': 'Reviewed with learner'},
    'GenerateIn': {'topic': 'Everyday English', 'count': 6, 'kinds': ['read', 'choice'], 'level': 'A1'},
    'CourseIn': {'title': 'Everyday English', 'summary': 'Short English practice lessons', 'level': 'A1', 'visibility': 'public', 'sequential': True},
    'CoursePatch': {'title': 'Everyday English — updated'},
    'TitleIn': {'title': 'Getting started'},
    'LessonIn': {'title': 'Greetings', 'intro': 'Read the sentence aloud.', 'items': [{'kind': 'read', 'text': 'Hello, how are you?'}]},
    'MoveIn': {'direction': 'up'}, 'PublishIn': {'published': True},
    'KnowledgeIn': {'skill_code': 'MORPH.AGREEMENT', 'title': 'He, she and it', 'body': 'In the simple present use she goes, he likes.', 'visibility': 'private'},
    'KnowledgeReviewIn': {'version': '{{knowledge_version}}'},
    'KnowledgeUpdateIn': {'skill_code': 'MORPH.AGREEMENT', 'title': 'He, she and it', 'body': 'Use she goes and he likes in the simple present.', 'version': '{{knowledge_version}}'},
    'ClassCourseIn': {'course_id': '{{course_id}}'},
}



# Inspect endpoint signatures as well, because included routers differ between FastAPI releases.
import inspect
import main
import courses
import operations
import growth
import generation_jobs

def access(operation):
    operation_id = operation['operationId']
    for module in (main, courses, operations, growth, generation_jobs):
        for name, fn in vars(module).items():
            if inspect.isfunction(fn) and operation_id.startswith(name + '_'):
                deps = {getattr(getattr(p.default, 'dependency', None), '__name__', '') for p in inspect.signature(fn).parameters.values()}
                if 'teacher_only' in deps:
                    return 'Teacher'
                if 'learner_only' in deps:
                    return 'Learner (student or learner)'
                if 'current_user' in deps:
                    return 'Authenticated (ownership/membership rules apply)'
    return 'Public'


def group(path):
    if '/teacher/knowledge' in path: return 'Teaching knowledge'
    if '/auth/' in path: return 'Authentication'
    if path == '/api/health': return 'Health'
    if '/attention' in path or '/performance' in path or '/skill-grid' in path or '/students/' in path: return 'Class insights and students'
    if '/assignments' in path: return 'Assignments'
    if '/recordings' in path: return 'Recordings'
    if '/attempts' in path: return 'Attempts'
    if '/courses' in path: return 'Courses'
    if '/units/' in path: return 'Units'
    if '/lessons/' in path: return 'Lessons'
    if '/classes' in path: return 'Classes'
    if '/ai/' in path: return 'AI'
    if '/me' in path: return 'Profile and progress'
    return 'Catalog'

captures = {
    ('post', '/api/teacher/knowledge'): {'knowledge_id': 'id', 'knowledge_version': 'version'},
    ('put', '/api/teacher/knowledge/{unit_id}'): {'knowledge_version': 'version'},
    ('post', '/api/classes'): {'class_id': 'id', 'class_code': 'code'},
    ('post', '/api/classes/{class_id}/code'): {'class_code': 'code'},
    ('post', '/api/recordings'): {'rec_id': 'id'},
    ('post', '/api/classes/{class_id}/assignments'): {'assignment_id': 'id'},
    ('post', '/api/attempts'): {'attempt_id': 'id'},
    ('post', '/api/courses'): {'course_id': 'id'},
    ('post', '/api/courses/{course_id}/units'): {'unit_id': 'id'},
    ('post', '/api/units/{unit_id}/lessons'): {'lesson_id': 'id'},
}
def example_schema(schema):
    if '$ref' in schema:
        return example_schema(spec['components']['schemas'][schema['$ref'].split('/')[-1]])
    if 'default' in schema and schema['default'] is not None: return schema['default']
    if 'anyOf' in schema: return example_schema(next((s for s in schema['anyOf'] if s.get('type')!='null'), schema['anyOf'][0]))
    if 'enum' in schema: return schema['enum'][0]
    kind=schema.get('type')
    if kind=='object': return {k:example_schema(v) for k,v in schema.get('properties',{}).items()}
    if kind=='array': return []
    if kind=='boolean': return True
    if kind=='integer': return 1
    return '2026-12-01T10:00:00Z' if schema.get('format')=='date-time' else 'replace-me'

folders = {}
listing = ['VaachakAI classroom API — complete route inventory', 'Base URL: http://localhost:8000', 'Source: FastAPI app.openapi(); regenerate with python tools/export_postman.py', '']
for path, methods in spec['paths'].items():
    for method, op in methods.items():
        permission = access(op)
        url_path = re.sub(r'\{(\w+)\}', r'{{\1}}', path)
        if '/teacher/knowledge/' in path:
            url_path = url_path.replace('{{unit_id}}', '{{knowledge_id}}')
        query = [{'key': p['name'], 'value': str(p['schema'].get('default', '')), 'disabled': not p.get('required', False)} for p in op.get('parameters', []) if p['in'] == 'query']
        description = f'Access: {permission}.\n\n' + op.get('description', '')
        if method == 'delete': description += '\nDeletes/removes the selected resource or relationship.'
        if path == '/api/attempts' and method == 'post':
            description += '\nSend exactly one of set_id, assignment_id, or lesson_id. Enable choice for quizzes; use transcript or audio for speaking tasks. item_index is zero-based.'
        request = {'method': method.upper(), 'header': [], 'url': {'raw': '{{base_url}}' + url_path, 'host': ['{{base_url}}'], 'path': url_path.lstrip('/').split('/')}, 'description': description}
        if query: request['url']['query'] = query
        if permission == 'Public': request['auth'] = {'type': 'noauth'}
        content = op.get('requestBody', {}).get('content', {})
        if 'application/json' in content:
            schema_name = content['application/json']['schema']['$ref'].split('/')[-1]
            raw = json.dumps(examples.get(schema_name, example_schema(spec['components']['schemas'][schema_name])), indent=2)
            # Numeric ID variables must become JSON numbers after substitution.
            raw = re.sub(r'"(\{\{(?:student_id|course_id)\}\})"', r'\1', raw)
            request['header'] = [{'key': 'Content-Type', 'value': 'application/json'}]
            request['body'] = {'mode': 'raw', 'raw': raw, 'options': {'raw': {'language': 'json'}}}
        elif 'multipart/form-data' in content:
            schema_name = content['multipart/form-data']['schema']['$ref'].split('/')[-1]
            schema = spec['components']['schemas'][schema_name]
            values = {'title': 'Greeting recording', 'duration_ms': '3000', 'item_index': '0', 'transcript': 'She goes to school.', 'choice': '0', 'assignment_id': '{{assignment_id}}', 'lesson_id': '{{lesson_id}}', 'set_id': '{{set_id}}'}
            fields = []
            for key in schema['properties']:
                file = key in ('file', 'audio')
                field = {'key': key, 'type': 'file' if file else 'text'}
                field['src' if file else 'value'] = [] if file else values.get(key, '')
                if key in ('audio', 'choice', 'assignment_id', 'lesson_id', 'practice_session_id', 'transcription_id', 'client_uuid', 'item_version', 'retry_of_attempt_id'): field['disabled'] = True
                if file: field['description'] = 'Select a local audio file in Postman.'
                fields.append(field)
            request['body'] = {'mode': 'formdata', 'formdata': fields}
        scripts = []
        if path in ('/api/auth/register', '/api/auth/login'):
            scripts = ['if (pm.response.code === 200) {', '  const data = pm.response.json();', '  pm.collectionVariables.set("token", data.token);', '  if (data.user.role !== "teacher") pm.collectionVariables.set("student_id", String(data.user.id));', '}']
        elif path == '/api/auth/logout':
            scripts = ['if (pm.response.code === 200) pm.collectionVariables.set("token", "");']
        elif (method, path) in captures:
            scripts = ['if (pm.response.code >= 200 && pm.response.code < 300) {', '  const data = pm.response.json();']
            for variable, field in captures[(method, path)].items():
                scripts += [f'  if (data.{field} !== undefined) pm.collectionVariables.set("{variable}", String(data.{field}));']
            scripts += ['}']
        item = {'name': op['summary'], 'request': request, 'response': []}
        if scripts: item['event'] = [{'listen': 'test', 'script': {'type': 'text/javascript', 'exec': scripts}}]
        folders.setdefault(group(path), []).append(item)
        listing.append(f'{method.upper():7} {path:58} {permission}')

collection = {
    'info': {'name': 'VaachakAI Classroom API', 'schema': 'https://schema.getpostman.com/json/collection/v2.1.0/collection.json',
             'description': 'All ' + str(sum(len(items) for items in folders.values())) + ' classroom API operations. Set base_url, name, email, password and role; run Register or Login to save token automatically. Authenticated requests inherit Bearer {{token}}. Switch credentials and log in again for teacher vs learner actions. Creation requests save resource IDs. Empty ID variables must be populated before use. Select local files for uploads. This is an endpoint reference, not an ordered collection-runner workflow; choose requests individually, especially deletion/logout. API docs: {{base_url}}/api/docs. Supabase deployment-generated endpoints are separate and are not part of this collection.'},
    'auth': {'type': 'bearer', 'bearer': [{'key': 'token', 'value': '{{token}}', 'type': 'string'}]},
    'variable': [{'key': key, 'value': value, 'type': 'string'} for key, value in variables.items()],
    'item': [{'name': name, 'item': items} for name, items in folders.items()],
}
out = ROOT / 'postman'
out.mkdir(exist_ok=True)
(out / 'VaachakAI.postman_collection.json').write_text(json.dumps(collection, indent=2) + '\n')
(out / 'openapi.json').write_text(json.dumps(spec, indent=2) + '\n')
listing += ['', 'Documentation endpoints (not application operations):', 'GET /api/docs', 'GET /docs/oauth2-redirect', 'GET /api/openapi.json', 'GET /redoc', '']
(out / 'API_LIST.txt').write_text('\n'.join(listing))
print(f'Exported {sum(len(items) for items in folders.values())} API operations to {out}')
