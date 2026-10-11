// Disposable local API only. Keep the output file and runner logs out of Git.
import fs from 'node:fs/promises';
import { randomUUID } from 'node:crypto';

const base = 'http://127.0.0.1:8008/api';
const output = process.argv[2];
if (!output) throw new Error('Usage: node scripts/seed-ios.mjs /tmp/new-ios-accounts.json');
const file = await fs.open(output, 'wx', 0o600);
async function post(path, body, token) {
  const response = await fetch(base + path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: JSON.stringify(body),
  });
  if (!response.ok) throw new Error(`iOS fixture setup failed: ${path} (${response.status})`);
  return response.json();
}
try {
  const accounts = {};
  for (const role of ['teacher', 'learner']) {
    const email = `ios-${role}-${randomUUID()}@example.invalid`;
    const password = `Test-${randomUUID()}!`;
    const account = await post('/auth/register', {
      name: role === 'teacher' ? 'iOS Teacher' : 'iOS Learner', email, password, role,
    });
    accounts[role] = { email, password, token: account.token };
  }
  const classroom = await post('/classes', { name: 'iOS runtime classroom', standard: 'adult' }, accounts.teacher.token);
  await post('/classes/join', { code: classroom.code }, accounts.learner.token);
  await post(`/classes/${classroom.id}/assignments`, {
    title: 'iOS runtime practice',
    items: [
      { kind: 'choice', prompt: 'She ___ English every day.', options: ['practise', 'practises'], correct: 1, explain: 'Use practises with she.' },
      { kind: 'read', text: 'I learn something new every day.' },
    ],
  }, accounts.teacher.token);
  await file.writeFile(JSON.stringify(accounts, null, 2) + '\n');
  console.log('Created synthetic iOS accounts and classroom; private credentials saved.');
} finally {
  await file.close();
}
