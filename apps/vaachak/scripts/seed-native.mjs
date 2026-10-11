// Seed only the disposable local test API. Never point this at production.
import fs from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
const base = 'http://127.0.0.1:8002/api';
const output = process.argv[2];
if (!output) throw new Error('Usage: node scripts/seed-native.mjs /tmp/new-native-account.json');
const file = await fs.open(output, 'wx', 0o600);
const password = `Test-${randomUUID()}!`;
async function post(path, body, token) {
  const response = await fetch(base + path, { method: 'POST', headers: {
    'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}),
  }, body: JSON.stringify(body) });
  if (!response.ok) throw new Error(`Test setup failed: ${path} (${response.status})`);
  return response.json();
}
try {
  const email = `native-${randomUUID()}@example.invalid`;
  const learner = await post('/auth/register', { name: 'Native Learner', email, password, role: 'learner' });
  const teacher = await post('/auth/register', { name: 'Native Instructor', email: `native-teacher-${randomUUID()}@example.invalid`, password, role: 'teacher' });
  const classroom = await post('/classes', { name: 'Native practice', standard: 'adult' }, teacher.token);
  await post('/classes/join', { code: classroom.code }, learner.token);
  await post(`/classes/${classroom.id}/assignments`, { title: 'Two useful steps', items: [
    { kind: 'choice', prompt: 'She ___ English every day.', options: ['practise', 'practises'], correct: 1, explain: 'Use practises with she.' },
    { kind: 'read', text: 'I learn something new every day.' },
  ] }, teacher.token);
  await file.writeFile(JSON.stringify({ email, password }, null, 2) + '\n');
  console.log('Synthetic account and classroom created. Credentials saved in the requested private file.');
} finally { await file.close(); }
