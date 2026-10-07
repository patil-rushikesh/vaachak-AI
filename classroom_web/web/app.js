/* Vaachak English classroom: single-page app, no build step. */
const $app = document.getElementById('app');
const state = { token: localStorage.getItem('vc_token'), user: null, health: {} };

/* ------------------------------------------------------------------ helpers */
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];
function toast(msg) { const t = $('#toast'); t.textContent = msg; t.classList.add('show'); clearTimeout(toast.t); toast.t = setTimeout(() => t.classList.remove('show'), 4200); }
function ago(iso) {
  if (!iso) return 'No activity yet';
  const m = Math.round((Date.now() - new Date(iso)) / 60000);
  if (m < 2) return 'Just now'; if (m < 60) return m + ' min ago';
  const h = Math.round(m / 60); if (h < 24) return h + ' h ago';
  const d = Math.round(h / 24); return d === 1 ? 'Yesterday' : d + ' days ago';
}
function due(iso) {
  if (!iso) return '';
  const d = new Date(iso), days = Math.ceil((d - Date.now()) / 86400000);
  const when = d.toLocaleDateString(undefined, { day: 'numeric', month: 'short' });
  return days < 0 ? `Was due ${when}` : days === 0 ? 'Due today' : `Due ${when}`;
}
const standardLabel = c => c.standard ? (c.standard === 'adult' ? 'Adult' : 'Std ' + c.standard) + (c.section || '') : '';
const place = c => [c.district, c.pincode].filter(Boolean).join(' ');
const LANG = { en: 'English', hi: 'Hindi', mr: 'Marathi', gu: 'Gujarati', bn: 'Bengali', ta: 'Tamil', te: 'Telugu', kn: 'Kannada', ml: 'Malayalam', pa: 'Punjabi', or: 'Odia', ur: 'Urdu' };
const KIND_LABEL = { read: 'Read aloud', free: 'Speak an answer', build: 'Build a sentence', choice: 'Multiple choice', fill: 'Fill in the blank', listen: 'Listen and choose' };
const QUIZ = ['choice', 'fill', 'listen'];
const classMeta = c => [standardLabel(c), place(c), LANG[c.language] || c.language].filter(Boolean).join(' · ');

async function api(path, { method = 'GET', body, form } = {}) {
  const headers = {};
  if (state.token) headers.Authorization = 'Bearer ' + state.token;
  let payload;
  if (form) payload = form; else if (body !== undefined) { headers['Content-Type'] = 'application/json'; payload = JSON.stringify(body); }
  const res = await fetch('/api' + path, { method, headers, body: payload });
  if (res.status === 401 && state.token) { signOutLocal(); throw new Error('Your session ended. Sign in again.'); }
  const data = res.headers.get('content-type')?.includes('json') ? await res.json() : null;
  if (!res.ok) {
    const d = data?.detail;
    throw new Error(typeof d === 'string' ? d : Array.isArray(d) ? d.map(x => (x.loc?.slice(-1)[0] || '') + ': ' + x.msg).join('; ') : 'Something went wrong.');
  }
  return data;
}
function signOutLocal() { state.token = null; state.user = null; localStorage.removeItem('vc_token'); location.hash = '#/login'; }
const audioUrl = (kind, id) => `/api/${kind}/${id}/audio?token=${encodeURIComponent(state.token)}`;

/* ------------------------------------------------------------------ voice */
function makeRecorder() {
  const SR = window.SpeechRecognition || window.webkitSpeechRecognition;
  let mr, stream, chunks = [], t0 = 0, rec = null;
  return {
    speechSupported: !!SR && !!window.MediaRecorder,
    async start(onText) {
      stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      chunks = [];
      const mime = ['audio/webm;codecs=opus', 'audio/webm', 'audio/mp4', 'audio/ogg'].find(m => MediaRecorder.isTypeSupported(m));
      mr = new MediaRecorder(stream, mime ? { mimeType: mime } : undefined);
      mr.ondataavailable = e => e.data.size && chunks.push(e.data);
      mr.start(); t0 = Date.now();
      if (SR && onText) {
        rec = new SR(); rec.lang = 'en-IN'; rec.interimResults = true; rec.continuous = true;
        let final = '';
        rec.onresult = e => {
          let interim = '';
          for (let i = e.resultIndex; i < e.results.length; i++) { const r = e.results[i]; if (r.isFinal) final += r[0].transcript + ' '; else interim += r[0].transcript; }
          onText((final + interim).trim());
        };
        rec.onerror = () => {};
        try { rec.start(); } catch { /* already started */ }
      }
    },
    stop() {
      return new Promise(resolve => {
        try { rec && rec.stop(); } catch { /* ignore */ }
        mr.onstop = () => { stream.getTracks().forEach(t => t.stop()); resolve({ blob: new Blob(chunks, { type: (mr.mimeType || 'audio/webm').split(';')[0] }), duration: Date.now() - t0 }); };
        mr.stop();
      });
    },
  };
}
function speak(text, rate = .9) {
  if (!('speechSynthesis' in window)) return toast('This browser cannot read aloud.');
  speechSynthesis.cancel();
  const u = new SpeechSynthesisUtterance(text); u.lang = 'en-IN'; u.rate = rate; speechSynthesis.speak(u);
}

/* ------------------------------------------------------------------ shell */
function shell(inner, active) {
  const u = state.user;
  const nav = u.role === 'teacher' ? [['#/classes', 'Classes', 'classes'], ['#/courses', 'Courses', 'courses']]
    : [['#/today', 'Today', 'today'], ['#/courses', 'Courses', 'courses'], ['#/practice', 'Practice', 'practice'],
       ['#/classes', 'Classes', 'classes'], ['#/progress', 'My progress', 'progress']];
  return `<header class="bar"><a class="brand" href="#/"><i></i>Vaachak</a>
    <nav aria-label="Main">${nav.map(([h, t, k]) => `<a href="${h}" ${active === k ? 'aria-current="page"' : ''}>${t}</a>`).join('')}</nav>
    <div class="who"><span>${esc(u.name)}</span><span class="role">${{ teacher: 'Teacher', student: 'Student', learner: 'Self-learner' }[u.role]}</span><button class="btn ghost" id="signout">Sign out</button></div></header>
    <main>${inner}</main>`;
}
/* Audio recorded in the browser has no duration written into it, so players show 0:00 and
   refuse to seek. Nudging currentTime once makes the browser work the real length out. */
function fixAudioDuration(root = document) {
  $$('audio', root).forEach(el => {
    if (el.dataset.fixed) return;
    el.dataset.fixed = '1';
    const probe = () => {
      if (el.duration !== Infinity && !Number.isNaN(el.duration)) return;
      const onSeek = () => { el.currentTime = 0; el.removeEventListener('seeked', onSeek); };
      el.addEventListener('seeked', onSeek);
      try { el.currentTime = 1e101; } catch { /* nothing more we can do */ }
    };
    el.addEventListener('loadedmetadata', probe, { once: true });
    if (el.readyState > 0) probe();
  });
}

function mount(html, active) {
  $app.innerHTML = state.user ? shell(html, active) : html;
  fixAudioDuration($app);
  $('#signout')?.addEventListener('click', async () => { try { await api('/auth/logout', { method: 'POST' }); } catch { /* ignore */ } signOutLocal(); });
}
const loading = () => { $app.innerHTML = state.user ? shell('<p class="muted">Loading…</p>') : '<p class="muted" style="padding:2rem">Loading…</p>'; };
function fail(e) { mount(`<div class="empty"><h2>That did not load</h2><p>${esc(e.message)}</p><a class="btn" href="#/">Back to start</a></div>`); }

/* ------------------------------------------------------------------ auth */
function authScreen() {
  let mode = 'in', role = 'student';
  const draw = () => {
    $app.innerHTML = `<div class="auth"><h1>Speak English with confidence.</h1>
      <p class="muted">Classes, recorded lessons and feedback on your grammar and pronunciation.</p>
      <div class="seg" role="group" aria-label="Sign in or create account"><button type="button" data-mode="in" aria-pressed="${mode === 'in'}">Sign in</button><button type="button" data-mode="up" aria-pressed="${mode === 'up'}">Create account</button></div>
      <form id="auth" class="panel">
        ${mode === 'up' ? `<label for="name">Your name</label><input id="name" required maxlength="60" autocomplete="name">
        <label>I am a</label><div class="seg" role="group" aria-label="Role">${[['student', 'Student'], ['learner', 'Self-learner'], ['teacher', 'Teacher']].map(([v, t]) => `<button type="button" data-role="${v}" aria-pressed="${role === v}">${t}</button>`).join('')}</div>
        <p class="hint">${{ student: 'Join a class with the code your teacher gives you.', learner: 'Practise on your own. You can join a class later.', teacher: 'Create classes, record lessons and track progress.' }[role]}</p>` : ''}
        <label for="email">Email</label><input id="email" type="email" required autocomplete="email">
        <label for="pw">Password</label><input id="pw" type="password" required minlength="8" autocomplete="${mode === 'in' ? 'current-password' : 'new-password'}">
        <p class="err" id="autherr" role="alert"></p>
        <button class="btn primary" style="width:100%;justify-content:center">${mode === 'in' ? 'Sign in' : 'Create account'}</button>
      </form>
      ${state.health.demo ? `<details class="note"><summary>Demo accounts</summary><p>Password for all: <b>demo-pass-123</b><br>teacher@demo.test · aarav@demo.test (student) · meera@demo.test (self-learner)</p></details>` : ''}</div>`;
    $$('[data-mode]').forEach(b => b.onclick = () => { mode = b.dataset.mode; draw(); });
    $$('[data-role]').forEach(b => b.onclick = () => { role = b.dataset.role; const keep = { n: $('#name').value, e: $('#email').value }; draw(); $('#name').value = keep.n; $('#email').value = keep.e; });
    $('#auth').onsubmit = async ev => {
      ev.preventDefault();
      const body = { email: $('#email').value, password: $('#pw').value };
      if (mode === 'up') { body.name = $('#name').value; body.role = role; }
      try {
        const r = await api(mode === 'in' ? '/auth/login' : '/auth/register', { method: 'POST', body });
        state.token = r.token; state.user = r.user; localStorage.setItem('vc_token', r.token);
        location.hash = r.user.role === 'teacher' ? '#/classes' : '#/today'; route();
      } catch (e) { $('#autherr').textContent = e.message; }
    };
  };
  draw();
}

/* ------------------------------------------------------------------ classes */
function classCard(c) {
  const sub = [standardLabel(c), LANG[c.language]].filter(Boolean).join(' · ');
  return `<a class="cls band${c.color % 6}" href="#/class/${c.id}/${state.user.role === 'teacher' ? 'needs' : 'work'}"><div class="top"><h3>${esc(c.name)}</h3><p>${esc(sub)}</p></div>
    <div class="body"><span>${state.user.role === 'teacher' ? c.students + ' learner' + (c.students === 1 ? '' : 's') : 'Teacher: ' + esc(c.teacher)}</span><span>${esc(place(c))}</span></div></a>`;
}
async function classesPage() {
  loading();
  const classes = await api('/classes');
  const t = state.user.role === 'teacher';
  mount(`<div class="row" style="align-items:center;margin-bottom:18px"><h1 style="flex:2;margin:0">${t ? 'Your classes' : 'Your classes'}</h1>
    <div style="flex:0 0 auto">${t ? '<button class="btn primary" id="newclass">Create class</button>' : ''}</div></div>
    ${!t ? `<form id="join" class="panel row" style="align-items:end;margin-bottom:22px"><div><label for="code">Class code</label><input id="code" maxlength="12" placeholder="For example K7PQ2X" autocomplete="off" style="text-transform:uppercase"></div><div style="flex:0 0 auto"><button class="btn primary">Join class</button></div></form>` : ''}
    ${classes.length ? `<div class="cards">${classes.map(classCard).join('')}</div>` : `<div class="empty"><h2>${t ? 'No classes yet' : 'You have not joined a class'}</h2><p>${t ? 'Create a class, then share its code with your learners.' : 'Ask your teacher for the 6-character code and enter it above.'}</p></div>`}`, 'classes');
  $('#newclass')?.addEventListener('click', createClassDialog);
  $('#join')?.addEventListener('submit', async ev => {
    ev.preventDefault();
    try { const c = await api('/classes/join', { method: 'POST', body: { code: $('#code').value } }); toast('Joined ' + c.name); route(); } catch (e) { toast(e.message); }
  });
}
function createClassDialog() {
  const dlg = $('#dialog'), year = (() => { const d = new Date(), s = d.getMonth() >= 5 ? d.getFullYear() : d.getFullYear() - 1; return `${s}-${String((s + 1) % 100).padStart(2, '0')}`; })();
  const stds = ['KG', ...Array.from({ length: 12 }, (_, i) => String(i + 1)), 'adult'];
  dlg.innerHTML = `<form method="dialog"><h2>Create class</h2>
    <label for="cn">Class name</label><input id="cn" required maxlength="80" placeholder="English speaking">
    <div class="row"><div><label for="cs">Standard</label><select id="cs">${stds.map(s => `<option value="${s}">${s === 'adult' ? 'Adult learners' : s}</option>`).join('')}</select></div>
    <div><label for="csec">Section</label><input id="csec" maxlength="8" placeholder="A"></div></div>
    <div class="row"><div><label for="cp">Pincode</label><input id="cp" inputmode="numeric" pattern="[1-9][0-9]{5}" maxlength="6" required placeholder="411001"></div>
    <div><label for="cd">District</label><input id="cd" maxlength="60" required></div><div><label for="cst">State</label><input id="cst" maxlength="60" required></div></div>
    <label for="cl">Language of instruction</label><select id="cl">${Object.entries(LANG).map(([k, v]) => `<option value="${k}">${v}</option>`).join('')}</select>
    <p class="hint">Academic year ${year}. Learners join with a code you share.</p><p class="err" id="cerr" role="alert"></p>
    <div class="actions"><button type="button" class="btn" value="cancel" id="cancel">Cancel</button><button class="btn primary" id="save" value="ok">Create class</button></div></form>`;
  dlg.showModal();
  $('#cancel', dlg).onclick = () => dlg.close();
  $('form', dlg).onsubmit = async ev => {
    ev.preventDefault();
    try {
      const c = await api('/classes', { method: 'POST', body: { name: $('#cn').value, standard: $('#cs').value, section: $('#csec').value, pincode: $('#cp').value, district: $('#cd').value, state: $('#cst').value, language: $('#cl').value, academic_year: year } });
      dlg.close(); location.hash = `#/class/${c.id}/work`;
    } catch (e) { $('#cerr', dlg).textContent = e.message; }
  };
}

async function classPage(id, tab) {
  loading();
  const [c, work] = await Promise.all([api(`/classes/${id}`), api(`/classes/${id}/assignments`)]);
  const t = state.user.role === 'teacher';
  const tabs = t ? [['needs', 'Needs you'], ['work', 'Classwork'], ['courses', 'Courses'], ['skills', 'Skills'], ['people', 'People'], ['performance', 'Performance']]
    : [['work', 'Classwork'], ['courses', 'Courses']];
  const head = `<div class="classhead band${c.color % 6}"><h1>${esc(c.name)}</h1><p>${esc(classMeta(c))}</p>
    ${t ? `<div><span class="code" title="Learners enter this code to join">${esc(c.code)}</span> <button class="btn ghost" id="newcode" style="color:#fff">New code</button></div>` : `<p>Teacher: ${esc(c.teacher)}</p>`}</div>
    <div class="tabs" role="tablist">${tabs.map(([k, n]) => `<a href="#/class/${id}/${k}" ${tab === k ? 'aria-current="page"' : ''}>${n}</a>`).join('')}</div>`;
  let body = '';
  if (tab === 'needs' && t) body = await attentionTab(c);
  else if (tab === 'skills' && t) body = await skillGridTab(c);
  else if (tab === 'work') body = workTab(c, work, t);
  else if (tab === 'courses') body = await classCoursesTab(c, t);
  else if (tab === 'people' && t) body = peopleTab(c);
  else if (tab === 'performance' && t) body = await performanceTab(c);
  mount(head + body, 'classes');
  if (tab === 'courses' && t) bindClassCourses(c);
  if (tab === 'needs' && t) bindAttention(c);
  $('#newcode')?.addEventListener('click', async () => { await api(`/classes/${id}/code`, { method: 'POST' }); route(); });
  $('#newwork')?.addEventListener('click', () => assignmentDialog(c));
  $$('[data-del]').forEach(b => b.onclick = async ev => { ev.preventDefault(); if (confirm('Delete this assignment and its results?')) { await api('/assignments/' + b.dataset.del, { method: 'DELETE' }); route(); } });
  $$('[data-remove]').forEach(b => b.onclick = async () => { if (confirm('Remove this learner from the class?')) { await api(`/classes/${id}/students/${b.dataset.remove}`, { method: 'DELETE' }); route(); } });
  $$('tr[data-student]').forEach(r => { const go = () => location.hash = `#/class/${id}/student/${r.dataset.student}`; r.onclick = go; r.onkeydown = e => e.key === 'Enter' && go(); });
}
function workTab(c, work, t) {
  const rows = work.map(a => {
    const status = t ? `<span class="chip">${a.completed} of ${a.audience} finished</span>`
      : a.item_count === 0 ? '<span class="chip">Listen</span>' : a.done_items >= a.item_count ? '<span class="chip good">Done</span>' : `<span class="chip ${a.done_items ? 'warn' : ''}">${a.done_items} of ${a.item_count}</span>`;
    return `<a class="item" href="#/assignment/${a.id}"><div class="grow"><h3>${esc(a.title)}</h3><span class="muted small">${[a.targeted ? (t ? 'One learner' : 'Just for you') : '', a.recording_id ? 'Voice lesson' : '', a.item_count ? a.item_count + ' task' + (a.item_count > 1 ? 's' : '') : '', due(a.due_at)].filter(Boolean).join(' · ')}</span></div>${status}${t ? `<button class="btn ghost danger" data-del="${a.id}" aria-label="Delete ${esc(a.title)}">Delete</button>` : ''}</a>`;
  }).join('');
  return `${t ? '<p><button class="btn primary" id="newwork">New assignment</button></p>' : ''}${work.length ? `<div class="list">${rows}</div>` : `<div class="empty"><h2>No classwork yet</h2><p>${t ? 'Create an assignment from a practice set, your own sentences, or a recorded lesson.' : 'Your teacher has not assigned anything yet. You can still practise on your own.'}</p>${t ? '' : '<a class="btn" href="#/practice">Go to practice</a>'}</div>`}`;
}
function peopleTab(c) {
  return `<h2>Teacher</h2><p>${esc(c.teacher)}</p><h2>Learners (${c.roster.length})</h2>
    ${c.roster.length ? `<div class="list">${c.roster.map(s => `<div class="item"><div class="grow"><h3>${esc(s.name)}</h3><span class="muted small">${esc(s.email)}</span></div><button class="btn ghost danger" data-remove="${s.id}">Remove</button></div>`).join('')}</div>`
      : `<div class="empty"><h2>No learners yet</h2><p>Share the code <b>${esc(c.code)}</b>. Learners enter it under Classes.</p></div>`}`;
}
async function performanceTab(c) {
  const p = await api(`/classes/${c.id}/performance`);
  if (!p.students.length) return '<div class="empty"><h2>No learners yet</h2><p>Performance appears after learners join and practise.</p></div>';
  const meter = v => v == null ? '<span class="muted">–</span>' : `<div style="display:flex;gap:8px;align-items:center"><div class="bar-meter ${v < 60 ? 'low' : ''}" style="flex:1"><b style="width:${v}%"></b></div><span>${v}</span></div>`;
  return `<p class="muted">Class average <b>${p.class_avg ?? '–'}</b>. Select a learner to see their attempts and add extra practice.</p>
    <div class="scroll panel" style="padding:0"><table><thead><tr><th>Learner</th><th>Finished</th><th style="min-width:130px">Average</th><th style="min-width:130px">Last 10</th><th>Focus</th><th>Active</th></tr></thead><tbody>
    ${p.students.map(s => `<tr class="click" tabindex="0" data-student="${s.id}"><td><b>${esc(s.name)}</b> ${s.needs_help ? '<span class="chip bad">Needs help</span>' : ''}</td><td>${s.completed} of ${s.assigned}</td><td>${meter(s.avg_score)}</td><td>${meter(s.recent_avg)}</td><td>${esc(s.top_issue || '–')}</td><td class="muted">${ago(s.last_active)}</td></tr>`).join('')}</tbody></table></div>`;
}

async function studentPage(classId, sid) {
  loading();
  const [c, d] = await Promise.all([api(`/classes/${classId}`), api(`/classes/${classId}/students/${sid}`)]);
  const s = d.stats;
  mount(`<p><a href="#/class/${classId}/performance">← ${esc(c.name)}</a></p>
    <div class="row" style="align-items:center"><h1 style="flex:3;margin:0">${esc(d.student.name)}</h1><div style="flex:0 0 auto"><button class="btn primary" id="extra">Add extra practice</button></div></div>
    <p class="muted">${esc(d.student.email)} · ${s.attempts} attempt${s.attempts === 1 ? '' : 's'} in this class · last active ${ago(s.last_active)}</p>
    <div class="cols"><div><h2>Recent attempts</h2>${d.recent.length ? `<div class="list">${d.recent.map(a => `<div class="panel"><div class="row" style="align-items:center"><b style="flex:3">${esc(a.assignment)}</b><span class="chip ${a.score >= 80 ? 'good' : a.score >= 60 ? 'warn' : 'bad'}" style="flex:0 0 auto">${a.score} / 100</span></div>
        ${a.target ? `<p class="small muted" style="margin:6px 0 0">Target: ${esc(a.target)}</p>` : ''}<p style="margin:4px 0">Heard: “${esc(a.transcript)}”</p>${a.tips.map(t => `<div class="tip small">${esc(t)}</div>`).join('')}
        ${a.has_audio ? `<audio controls preload="metadata" src="${audioUrl('attempts', a.id)}" style="width:100%;margin-top:8px"></audio>` : ''}<span class="muted small">${ago(a.created_at)}</span></div>`).join('')}</div>` : '<div class="empty">No attempts yet.</div>'}</div>
    <aside><h2>Last 14 days</h2>${chart(s.days)}<h2 style="margin-top:24px">Grammar to review</h2>${focusList(s.grammar_focus.map(g => [g.skill, g.count + '×']))}
    <h2 style="margin-top:24px">Sounds to practise</h2>${focusList(s.sound_focus.map(w => [`${w.target} (heard “${w.said}”)`, w.count + '×']))}</aside></div>`, 'classes');
  $('#extra').onclick = () => assignmentDialog(c, d.student);
}
function focusList(rows) { return rows.length ? `<div class="list">${rows.map(([a, b]) => `<div class="item" style="padding:8px 14px"><span class="grow">${esc(a)}</span><span class="chip">${esc(b)}</span></div>`).join('')}</div>` : '<p class="muted">Nothing flagged yet.</p>'; }
function chart(days) {
  return `<div class="chart" role="img" aria-label="Average score per day, last 14 days">${days.map(d => `<div title="${d.day}: ${d.avg ?? 'no practice'}"><b style="height:${d.avg ?? 0}%;${d.avg == null ? 'background:transparent' : ''}"></b></div>`).join('')}</div>
    <div class="chart labels">${days.map((d, i) => `<span>${i % 3 === 0 ? new Date(d.day).getDate() : ''}</span>`).join('')}</div>`;
}

/* ------------------------------------------------------------------ teacher: new assignment */
async function assignmentDialog(c, student = null, seed = {}) {
  const dlg = $('#dialog');
  const langSets = (await api('/catalog')).find(l => l.code === 'en').sets;
  const roster = (await api(`/classes/${c.id}`)).roster;
  let clip = null; const rec = makeRecorder(); let recording = false;
  dlg.innerHTML = `<form method="dialog"><h2>${student ? 'Extra practice for ' + esc(student.name) : 'New assignment'}</h2>
    <label for="at">Title</label><input id="at" required maxlength="120" placeholder="Verb endings" value="${esc(seed.title || '')}">
    <label for="ai">Instructions (optional)</label><textarea id="ai" maxlength="500"></textarea>
    <label>Tasks</label><div class="seg" role="group" aria-label="Task source"><button type="button" data-src="set" aria-pressed="true">Practice set</button><button type="button" data-src="own" aria-pressed="false">Write my own tasks</button></div>
    <div id="srcset"><select id="aset" aria-label="Practice set">${langSets.map(s => `<option value="${s.id}">${esc(s.title)} · ${esc(s.skill)} (${s.item_count})</option>`).join('')}</select></div>
    <div id="srcown" hidden>${state.health.ai ? '<p><button type="button" class="btn" id="gen">Draft tasks with AI</button></p>' : ''}<div id="itemed"></div></div>
    <label>Voice lesson (optional)</label><div class="say" style="margin:4px 0"><button type="button" class="btn rec" id="recbtn">● Record</button><span id="rectime" class="muted"></span></div><audio id="recplay" controls hidden style="width:100%"></audio>
    <p class="hint">Learners can play your recording before they practise. Recording happens in your browser.</p>
    <div class="row"><div><label for="aaud">Assign to</label><select id="aaud"><option value="">Whole class</option>${roster.map(r => `<option value="${r.id}" ${student && student.id === r.id ? 'selected' : ''}>${esc(r.name)} only</option>`).join('')}</select></div>
    <div><label for="adue">Due date (optional)</label><input id="adue" type="date"></div></div>
    <p class="err" id="aerr" role="alert"></p><div class="actions"><button type="button" class="btn" id="acancel">Cancel</button><button class="btn primary" id="asave">Assign</button></div></form>`;
  dlg.showModal();
  const editor = makeItemEditor($('#itemed', dlg), []);
  $('#gen', dlg)?.addEventListener('click', () => generateDialog(editor, { topic: $('#at', dlg).value }));
  if (seed.topic) {   // arrived from "needs you": start on own tasks, aimed at the weak skill
    $('[data-src="own"]', dlg).click();
    if (state.health.ai) generateDialog(editor, { topic: seed.topic });
  }
  let src = 'set';
  $$('[data-src]', dlg).forEach(b => b.onclick = () => { src = b.dataset.src; $$('[data-src]', dlg).forEach(x => x.setAttribute('aria-pressed', x === b)); $('#srcset', dlg).hidden = src !== 'set'; $('#srcown', dlg).hidden = src !== 'own'; });
  $('#acancel', dlg).onclick = () => dlg.close();
  let timer;
  $('#recbtn', dlg).onclick = async () => {
    const btn = $('#recbtn', dlg);
    if (!recording) {
      try { await rec.start(); } catch { return toast('Microphone is blocked. Allow it in the browser address bar.'); }
      recording = true; btn.textContent = '■ Stop'; btn.classList.add('live'); const t0 = Date.now();
      timer = setInterval(() => { const s = Math.floor((Date.now() - t0) / 1000); $('#rectime', dlg).textContent = `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`; if (s >= 300) btn.click(); }, 250);
    } else {
      clearInterval(timer); recording = false; btn.classList.remove('live'); btn.textContent = '● Record again';
      clip = await rec.stop(); const p = $('#recplay', dlg); p.src = URL.createObjectURL(clip.blob); p.hidden = false;
      if (clip.duration < 1000) { clip = null; p.hidden = true; toast('That was too short. Record at least one second.'); }
    }
  };
  $('form', dlg).onsubmit = async ev => {
    ev.preventDefault();
    if (recording) return toast('Stop the recording first.');
    const err = $('#aerr', dlg), save = $('#asave', dlg); err.textContent = ''; save.disabled = true;
    try {
      const body = { title: $('#at').value, instructions: $('#ai').value || null, student_id: $('#aaud').value ? +$('#aaud').value : null,
        due_at: $('#adue').value ? new Date($('#adue').value + 'T23:59:00').toISOString() : null };
      if (src === 'set') body.set_id = $('#aset').value;
      else { const bad = editor.validate(); if (bad) throw new Error(bad); body.items = editor.getItems(); }
      if (clip) {
        const f = new FormData(); f.append('title', body.title); f.append('duration_ms', Math.round(clip.duration));
        f.append('file', clip.blob, 'lesson.' + (clip.blob.type.split('/')[1] || 'webm'));
        body.recording_id = (await api('/recordings', { method: 'POST', form: f })).id;
      }
      if (src === 'own' && !body.items.length && !body.recording_id) throw new Error('Add at least one sentence or a recording.');
      if (src === 'own' && !body.items.length) delete body.items;
      await api(`/classes/${c.id}/assignments`, { method: 'POST', body });
      dlg.close(); toast('Assigned'); route();
    } catch (e) { err.textContent = e.message; save.disabled = false; }
  };
  dlg.addEventListener('close', () => { clearInterval(timer); }, { once: true });
}

/* ------------------------------------------------------------------ practice runner */
async function assignmentPage(id) {
  loading();
  const a = await api('/assignments/' + id);
  if (state.user.role === 'teacher') return teacherAssignment(a);
  const recording = a.recording_id ? `<div class="panel" style="margin-bottom:18px"><b>Your teacher's recording</b><audio controls preload="metadata" src="${audioUrl('recordings', a.recording_id)}" style="width:100%;margin-top:8px"></audio></div>` : '';
  runner({ title: a.title, intro: (a.instructions ? `<p>${esc(a.instructions)}</p>` : '') + recording, items: a.items, best: a.best, back: `#/class/${a.class_id}/work`, backLabel: 'Classwork',
    send: (i, fd) => { fd.append('assignment_id', id); fd.append('item_index', i); return api('/attempts', { method: 'POST', form: fd }); } });
}
async function teacherAssignment(a) {
  const [c, perf] = await Promise.all([api('/classes/' + a.class_id), api(`/classes/${a.class_id}/performance`)]);
  mount(`<p><a href="#/class/${a.class_id}/work">← Classwork</a></p><h1>${esc(a.title)}</h1><p class="muted">${esc(c.name)} · ${a.completed} of ${a.audience} finished · ${due(a.due_at) || 'No due date'}</p>
    ${a.instructions ? `<p>${esc(a.instructions)}</p>` : ''}${a.recording_id ? `<div class="panel" style="margin-bottom:18px"><b>Voice lesson</b><audio controls preload="metadata" src="${audioUrl('recordings', a.recording_id)}" style="width:100%;margin-top:8px"></audio></div>` : ''}
    <h2>Tasks</h2><div class="list">${a.items.map((it, i) => `<div class="item"><span class="chip">${KIND_LABEL[it.kind] || it.kind}</span><span class="grow">${esc(it.text || it.prompt || it.answer)}</span></div>`).join('') || '<p class="muted">Listening only.</p>'}</div>
    <h2 style="margin-top:24px">Learners</h2><div class="list">${perf.students.filter(s => !a.student_id || s.id === a.student_id).map(s => `<a class="item" href="#/class/${a.class_id}/student/${s.id}"><span class="grow">${esc(s.name)}</span><span class="muted small">${ago(s.last_active)}</span></a>`).join('')}</div>`, 'classes');
}
async function practiceSet(setId) {
  loading();
  const s = await api('/sets/' + setId);
  runner({ title: s.title, intro: `<p class="muted">${esc(s.about)}</p>`, items: s.items, best: s.best, back: '#/practice', backLabel: 'Practice',
    send: (i, fd) => { fd.append('set_id', setId); fd.append('item_index', i); return api('/attempts', { method: 'POST', form: fd }); } });
}

function runner({ title, intro, items, best = {}, back, backLabel, send, finish }) {
  let idx = 0; const scores = { ...best };
  const rec = makeRecorder(); let live = false, clip = null, built = [], result = null;
  const first = items.findIndex((_, i) => scores[i] == null); idx = first < 0 ? 0 : first;
  const shuffle = a => { const r = [...a]; for (let i = r.length - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); [r[i], r[j]] = [r[j], r[i]]; } return r; };
  let pool = null;
  const draw = () => {
    if (!items.length) return mount(`<p><a href="${back}">← ${backLabel}</a></p><h1>${esc(title)}</h1>${intro}<div class="empty">This assignment is a listening lesson. Play the recording above.</div>`, 'classes');
    const it = items[idx]; result = null; clip = null;
    if (it.kind === 'build') { built = []; let p; do p = shuffle(it.words); while (p.join() === it.words.join() && it.words.length > 2); pool = p.map((w, i) => ({ w, i, used: false })); }
    mount(`<p><a href="${back}">← ${backLabel}</a></p><h1>${esc(title)}</h1>${intro}
      <div class="steps" aria-label="Progress">${items.map((_, i) => `<span class="${scores[i] != null ? 'done' : ''} ${i === idx ? 'now' : ''}"></span>`).join('')}</div>
      <div class="sheet" id="card"><p class="muted small">Task ${idx + 1} of ${items.length}${scores[idx] != null ? ` · your best so far ${scores[idx]}` : ''}</p>${taskBody(it)}</div>
      <div class="row" style="margin-top:14px"><button class="btn" id="prev" ${idx === 0 ? 'disabled' : ''}>Previous</button><button class="btn" id="next" ${idx === items.length - 1 ? 'disabled' : ''}>Next</button></div>`, location.hash.startsWith('#/practice') ? 'practice' : 'classes');
    bindTask(it);
    $('#prev').onclick = () => { idx--; draw(); }; $('#next').onclick = () => { idx++; draw(); };
  };
  const quizBody = it => {
    const stem = it.kind === 'listen' ? '<p class="prompt small">What do you hear?</p><div class="say" style="margin-top:0"><button class="btn" id="hear">▶ Hear it</button><button class="btn ghost" id="hearslow">Slower</button></div>'
      : it.kind === 'fill' ? `<p class="prompt">${esc(it.prompt).replace('___', '<span class="blank" aria-label="blank"></span>')}</p>`
        : `<p class="prompt">${esc(it.prompt)}</p>`;
    return `${stem}<div class="opts" role="radiogroup" aria-label="Answers">${it.options.map((o, i) => `<button type="button" class="opt" role="radio" aria-checked="false" data-o="${i}">${esc(o)}</button>`).join('')}</div>
      <div class="say"><button class="btn primary" id="check" disabled>Check</button></div><div id="out"></div>`;
  };
  const taskBody = it => {
    if (QUIZ.includes(it.kind)) return quizBody(it);
    if (it.kind === 'build') return `<p class="prompt small">Put the words in order.</p><div class="words" id="pool">${pool.map(p => `<button type="button" data-p="${p.i}" ${p.used ? 'disabled' : ''}>${esc(p.w)}</button>`).join('')}</div>
      <div class="built" id="built" aria-label="Your sentence"></div><div class="say"><button class="btn primary" id="check">Check</button><button class="btn" id="reset">Start again</button></div><div id="out"></div>`;
    const target = it.kind === 'read' ? `<p class="prompt">${esc(it.text)}</p><button class="btn ghost" id="hear">▶ Hear it</button>` : `<p class="prompt">${esc(it.prompt)}</p>`;
    if (state.health.ai) {
      // The server listens, so there is one button and no typing step.
      return `${target}
        <div class="say"><button class="btn rec big" id="recbtn">● Record</button><span class="muted" id="status">Tap, say it out loud, then tap again.</span></div>
        <details id="typebox"><summary>Can't speak right now? Type your answer</summary>
          <label for="tx" class="sr">Type what you want to say</label><textarea id="tx" maxlength="1000" placeholder="Type your sentence"></textarea>
          <button class="btn" id="check">Check what I typed</button></details><div id="out"></div>`;
    }
    return `${target}<div class="say"><button class="btn rec" id="recbtn">● Record</button><span class="muted" id="status">${rec.speechSupported ? 'Say it, then stop. Your words appear below.' : 'This browser cannot turn speech into text. Record, then type what you said.'}</span></div>
      <label for="tx">What we heard (you can fix it)</label><textarea id="tx" maxlength="1000" placeholder="Your words appear here"></textarea>
      <div class="say"><button class="btn primary" id="check">Check my answer</button></div><div id="out"></div>`;
  };
  const bindTask = it => {
    const out = $('#out');
    const shown = (r, html) => {
      scores[idx] = Math.max(scores[idx] ?? 0, r.score);
      out.innerHTML = html;
      $('.steps span:nth-child(' + (idx + 1) + ')').classList.add('done');
      if (idx < items.length - 1) out.insertAdjacentHTML('beforeend', '<p><button class="btn primary" id="go">Next task</button></p>');
      else out.insertAdjacentHTML('beforeend', finish ? finish(scores) : `<p><b>All done.</b> <a class="btn" href="${back}">Back</a></p>`);
      $('#go')?.addEventListener('click', () => { idx++; draw(); });
      const tx = $('#tx');
      if (tx && r.transcript && !QUIZ.includes(items[idx].kind)) tx.value = r.transcript;
      $('#fixheard')?.addEventListener('click', () => { $('#typebox')?.setAttribute('open', ''); $('#tx')?.focus(); });
      out.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
    };
    const submit = async text => {
      const fd = new FormData(); fd.append('transcript', text);
      if (clip) fd.append('audio', clip.blob, 'attempt.' + (clip.blob.type.split('/')[1] || 'webm'));
      const btn = $('#check'); if (btn) btn.disabled = true;
      try { result = await send(idx, fd); shown(result, penSheet(result)); }
      catch (e) {
        out.innerHTML = `<div class="verdict no"><b>That did not go through</b><p class="small">${esc(e.message)}</p></div>`;
        $('#typebox')?.setAttribute('open', '');
        throw e;
      } finally { if (btn) btn.disabled = false; }
    };
    if (QUIZ.includes(it.kind)) {
      let pick = null;
      $('#hear')?.addEventListener('click', () => speak(it.text));
      $('#hearslow')?.addEventListener('click', () => speak(it.text, .6));
      $$('.opt').forEach(b => b.onclick = () => {
        if (result) return;
        pick = +b.dataset.o;
        $$('.opt').forEach(x => { x.classList.toggle('picked', x === b); x.setAttribute('aria-checked', x === b); });
        $('#check').disabled = false;
      });
      $('#check').onclick = async () => {
        if (pick == null || result) return;
        const fd = new FormData(); fd.append('choice', pick); $('#check').disabled = true;
        try {
          result = await send(idx, fd);
          $$('.opt').forEach((x, i) => { x.disabled = true; x.classList.remove('picked'); if (i === result.correct_index) x.classList.add('right'); else if (i === pick) x.classList.add('wrong'); });
          shown(result, quizSheet(result, it));
          $('#again')?.addEventListener('click', () => draw());
        } catch (e) { toast(e.message); $('#check').disabled = false; }
      };
      return;
    }
    if (it.kind === 'build') {
      const paint = () => { $('#built').innerHTML = built.map((p, k) => `<button type="button" class="chip mark" data-b="${k}" style="cursor:pointer;font-size:1.1rem">${esc(p.w)}</button>`).join(''); $$('#pool button').forEach(b => b.disabled = pool[+b.dataset.p].used); };
      $$('#pool button').forEach(b => b.onclick = () => { const p = pool[+b.dataset.p]; p.used = true; built.push(p); paint(); });
      $('#built').onclick = e => { const b = e.target.closest('[data-b]'); if (!b) return; const [p] = built.splice(+b.dataset.b, 1); p.used = false; paint(); };
      $('#reset').onclick = () => { pool.forEach(p => p.used = false); built = []; paint(); };
      $('#check').onclick = () => built.length === pool.length ? submit(built.map(p => p.w).join(' ')) : toast('Use every word first.');
      return;
    }
    $('#hear')?.addEventListener('click', () => speak(it.text));
    const btn = $('#recbtn'), tx = $('#tx'), status = $('#status');
    const serverListens = !!state.health.ai;
    btn.onclick = async () => {
      if (!live) {
        try { await rec.start(serverListens ? null : t => { tx.value = t; }); }
        catch { status.textContent = 'The microphone is blocked. Allow it from the icon in the address bar, or type instead.'; $('#typebox')?.setAttribute('open', ''); return; }
        live = true; btn.textContent = '■ Stop'; btn.classList.add('live');
        status.textContent = serverListens ? 'Listening… tap Stop when you finish.' : 'Listening…';
        return;
      }
      live = false; btn.classList.remove('live'); btn.textContent = '● Record again';
      clip = await rec.stop();
      if (!serverListens) {
        status.textContent = tx.value ? 'Check the words, fix any mistake, then press Check.' : 'We could not hear words. Type what you said, then press Check.';
        return;
      }
      if (!clip || clip.duration < 700) { status.textContent = 'That was too short. Tap Record and say the whole sentence.'; return; }
      btn.disabled = true; status.innerHTML = '<span class="thinking">Listening to what you said…</span>';
      try {
        await submit('');            // no text: the server turns the recording into words
      } catch { /* submit already reported it */ }
      btn.disabled = false; status.textContent = 'Tap Record to say it again.';
    };
    $('#check')?.addEventListener('click', () => live ? toast('Stop the recording first.') : submit(tx.value));
  };
  mount('<p class="muted">Loading…</p>');
  draw();
}

function quizSheet(r, it) {
  const extra = r.tips.filter(t => !t.startsWith('The right answer'));
  return `<div class="verdict ${r.correct ? 'ok' : 'no'}" role="status"><b>${r.correct ? 'Correct' : 'Not quite'}</b>
    ${r.correct ? '' : `<span> The answer is “${esc(r.target)}”.</span>`}
    ${it.kind === 'listen' ? `<p class="small">It said: “${esc(it.text)}”</p>` : ''}${extra.map(t => `<p class="small">${esc(t)}</p>`).join('')}
    ${r.correct ? '' : '<p><button class="btn" id="again">Try again</button></p>'}</div>`;
}
function penSheet(r) {
  let line = '';
  if (r.kind === 'read') {
    line = r.words.map(w => `<span class="w ${w.status}">${esc(w.target)}${w.status === 'wrong' && w.heard ? `<span class="fix">${esc(w.heard)}</span>` : ''}${w.status === 'missed' ? '<span class="fix">skipped</span>' : ''}</span>`).join(' ');
  } else if (r.kind === 'build') {
    line = `<span class="w ${r.score === 100 ? 'correct' : 'wrong'}">${esc(r.transcript)}</span>` + (r.score === 100 ? '' : `<br><span class="w correct">${esc(r.answer)}</span>`);
  } else {
    line = `<span class="w correct">${esc(r.transcript)}</span>`;
  }
  const fixes = r.grammar.map(g => `<li><del>${esc(g.said)}</del> → <ins>${esc(g.fix)}</ins><br><span class="muted small">${esc(g.why)}</span></li>`).join('');
  // Anything the model already said in a correction should not be repeated as a loose tip.
  const loose = (r.tips || []).filter(t => t !== r.verdict && !(r.strengths || []).includes(t) && !r.grammar.some(g => t.includes(g.said)));
  const praise = r.score >= 90 && !r.grammar.length;
  return `<div class="sheet pen" style="margin-top:22px"><div class="score" aria-label="Score ${r.score} out of 100"><span>${r.score}<small>of 100</small></span></div>
    ${r.verdict ? `<p class="verdict-line">${esc(r.verdict)}</p>` : ''}
    <div class="line">${line}</div>
    ${r.kind === 'read' ? `<p class="heard">We heard: “${esc(r.transcript)}”</p>` : ''}
    ${r.extra_words?.length ? `<p class="small muted">Extra words: ${r.extra_words.map(esc).join(', ')}</p>` : ''}
    ${fixes ? `<ul class="fixes">${fixes}</ul>` : ''}
    ${(r.strengths || []).map(t => `<div class="tip good">${esc(t)}</div>`).join('')}
    ${loose.map(t => `<div class="tip ${praise ? 'good' : ''}">${esc(t)}</div>`).join('')}
    ${r.next_line ? `<div class="next-line"><span class="muted small">Now try saying this</span><p class="prompt small" style="margin:4px 0 0">${esc(r.next_line)}</p></div>` : ''}
    ${r.kind !== 'build' ? '<p class="note"><button type="button" class="linkish" id="fixheard">Not what you said? Correct it</button></p>' : ''}
    ${r.kind === 'read' ? `<p class="note">The word marks compare what was heard with the sentence on the page${r.source === 'ai' ? '' : ', using a fixed list of rules'}. They judge the words, not your accent.</p>` : ''}</div>`;
}

/* ------------------------------------------------------------------ practice catalog + progress */
async function practicePage() {
  loading();
  let q = '', timer;
  const load = async () => {
    const langs = await api('/catalog?q=' + encodeURIComponent(q));
    const open = langs.filter(l => l.sets.length), soon = langs.filter(l => !l.sets.length);
    $('#results').innerHTML = langs.length ? open.map(l => `<section style="margin-bottom:28px"><h2>${esc(l.name)}</h2>
      <div class="cards">${l.sets.map(s => `<a class="cls band${(s.id.length + s.level.length) % 6}" href="#/practice/${s.id}"><div class="top"><h3>${esc(s.title)}</h3><p>${esc(s.skill)} · ${esc(s.level)}</p></div><div class="body"><span>${esc(s.about)}</span></div></a>`).join('')}</div></section>`).join('')
      + (soon.length ? `<section><h2>More languages, coming soon</h2><p class="muted">English is open now. These are planned next.</p><div class="row" style="flex-wrap:wrap;gap:8px">${soon.map(l => `<span class="chip">${esc(l.name)}${l.native !== l.name ? ' · ' + esc(l.native) : ''}</span>`).join('')}</div></section>` : '')
      : '<div class="empty"><h2>Nothing matches</h2><p>Try a language name, or a skill like grammar or pronunciation.</p></div>';
  };
  mount(`<h1>Practice</h1><p class="muted">Pick a set and speak. You get feedback on grammar and pronunciation after every answer.</p>
    <p><a class="btn" href="#/review">Review my weak spots</a> <a class="btn ghost" href="#/courses">Browse courses</a></p>
    <label for="q" class="sr">Search languages and practice sets</label><input id="q" type="search" placeholder="Search a language or skill: grammar, pronunciation, Marathi…" style="margin-bottom:24px"><div id="results"></div>`, 'practice');
  $('#q').oninput = e => { q = e.target.value; clearTimeout(timer); timer = setTimeout(load, 200); };
  await load();
}
async function progressPage() {
  loading();
  const s = await api('/me/stats');
  mount(`<h1>My progress</h1>${s.attempts ? `<div class="cols"><div><h2>Last 14 days</h2>${chart(s.days)}
    <p class="muted" style="margin-top:14px">${s.attempts} answer${s.attempts === 1 ? '' : 's'} · average ${s.avg_score} · last 10 average ${s.recent_avg} · ${s.streak_days} day streak</p>
    ${Object.keys(s.by_kind).length ? `<h2 style="margin-top:24px">By kind of task</h2>${focusList(Object.entries(s.by_kind).map(([k, v]) => [KIND_LABEL[k] || k, v + ' / 100']))}` : ''}
    ${s.classes.length ? `<h2 style="margin-top:24px">Your classes</h2><div class="list">${s.classes.map(c => `<a class="item" href="#/class/${c.id}/work"><span class="grow"><b>${esc(c.name)}</b></span><span class="chip ${c.completed === c.assignments && c.assignments ? 'good' : ''}">${c.completed} of ${c.assignments} done</span></a>`).join('')}</div>` : ''}</div>
    <aside><h2>What to work on</h2>${s.weak_skills && s.weak_skills.length
      ? `<div class="list">${s.weak_skills.map(w => `<div class="item" style="padding:10px 14px"><span class="grow"><b>${esc(w.label)}</b><br><span class="muted small">${plural(w.misses, 'time')}</span></span><a class="btn" href="#/review">Practise</a></div>`).join('')}</div>`
      : '<p class="muted">Nothing stands out yet.</p>'}<h2 style="margin-top:24px">Sounds to practise</h2>${focusList(s.sound_focus.map(w => [`${w.target} (heard “${w.said}”)`, w.count + '×']))}</aside></div>`
      : `<div class="empty"><h2>No answers yet</h2><p>Do one practice set and your progress shows up here.</p><a class="btn primary" href="#/practice">Start practising</a></div>`}`, 'progress');
}

/* ------------------------------------------------------------------ router */
async function route() {
  const h = location.hash.replace(/^#\/?/, '').split('/');
  if (!state.token) { if (h[0] !== 'login') location.hash = '#/login'; return authScreen(); }
  if (!state.user) { try { state.user = await api('/me'); } catch { return authScreen(); } }
  try {
    switch (h[0]) {
      case '': case 'login': location.hash = state.user.role === 'teacher' ? '#/classes' : '#/today'; return;
      case 'classes': return await classesPage();
      case 'class': return h[2] === 'student' ? await studentPage(h[1], h[3]) : await classPage(h[1], h[2] || (state.user.role === 'teacher' ? 'needs' : 'work'));
      case 'assignment': return await assignmentPage(h[1]);
      case 'practice': return h[1] ? await practiceSet(h[1]) : await practicePage();
      case 'progress': return await progressPage();
      case 'courses': return await coursesPage();
      case 'course': return h[2] === 'edit' || h[2] === 'learners' ? await courseBuilder(h[1], h[2]) : await coursePage(h[1]);
      case 'lesson': return h[2] === 'edit' ? await lessonEditor(h[1]) : await lessonPage(h[1]);
      case 'review': return await reviewPage();
      case 'today': return await todayPage();
      default: location.hash = state.user.role === 'teacher' ? '#/classes' : '#/today';
    }
  } catch (e) { fail(e); }
}
window.addEventListener('hashchange', route);
fetch('/api/health').then(r => r.json()).then(h => { state.health = h; }).catch(() => { }).finally(route);
