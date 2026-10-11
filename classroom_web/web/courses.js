/* Courses: teacher course builder, learner course path, lesson page, personal review.
   Loaded after app.js; uses its helpers ($, $$, api, mount, runner, esc, toast, ...). */

const plural = (n, w) => `${n} ${w}${n === 1 ? '' : 's'}`;
const meter = pct => `<div class="bar-meter" style="flex:1" role="img" aria-label="${pct}% complete"><b style="width:${pct}%"></b></div><span class="small">${pct}%</span>`;
const stars = n => '★'.repeat(n) + '☆'.repeat(3 - n);
const keepScroll = async fn => { const y = window.scrollY; await fn(); window.scrollTo(0, y); };

function courseCard(c, href, foot) {
  return `<a class="cls band${c.id % 6}" href="${href}"><div class="top"><h3>${esc(c.title)}</h3>
    <p>${esc(c.level)} · ${plural(c.units, 'unit')} · ${plural(c.lessons, 'lesson')}</p></div><div class="body" style="align-items:center;gap:10px">${foot}</div></a>`;
}

/* ------------------------------------------------------------------ task editor (used for lessons and assignments) */
function makeItemEditor(host, initial = []) {
  const blank = k => ({
    read: { kind: 'read', text: '' }, free: { kind: 'free', prompt: '' }, build: { kind: 'build', answer: '' },
    choice: { kind: 'choice', prompt: '', options: ['', ''], correct: 0, explain: '' },
    fill: { kind: 'fill', prompt: '', options: ['', ''], correct: 0, explain: '' },
    listen: { kind: 'listen', text: '', options: ['', ''], correct: 0, explain: '' },
  })[k];
  const adopt = i => ({ ...i, answer: i.answer ?? '', explain: i.explain || '', options: i.options ? [...i.options] : undefined });
  let items = initial.map(adopt);
  const stemKey = it => (it.kind === 'listen' || it.kind === 'read') ? 'text' : 'prompt';
  const fields = (it, n) => {
    if (it.kind === 'read') return `<label>Sentence to read aloud</label><input data-f="text" value="${esc(it.text)}" maxlength="300">`;
    if (it.kind === 'free') return `<label>Question to answer aloud</label><input data-f="prompt" value="${esc(it.prompt)}" maxlength="300">`;
    if (it.kind === 'build') return `<label>The correct sentence</label><input data-f="answer" value="${esc(it.answer)}" maxlength="300"><p class="hint">Learners see these words shuffled and put them in order.</p>`;
    const label = { choice: 'Question', fill: 'Sentence (type ___ where the word goes)', listen: 'Sentence the learner will hear' }[it.kind];
    return `<label>${label}</label><input data-f="${stemKey(it)}" value="${esc(it[stemKey(it)])}" maxlength="300">
      <label>Answers <span class="muted small">(tick the correct one)</span></label>
      ${it.options.map((o, i) => `<div class="optrow"><input type="radio" name="c${n}" data-correct="${i}" ${it.correct === i ? 'checked' : ''} aria-label="Option ${i + 1} is correct">
        <input data-opt="${i}" value="${esc(o)}" placeholder="Option ${i + 1}" maxlength="120" aria-label="Option ${i + 1}">
        ${it.options.length > 2 ? `<button type="button" class="btn ghost" data-rmopt="${i}" aria-label="Remove option ${i + 1}">Remove</button>` : ''}</div>`).join('')}
      ${it.options.length < 6 ? '<button type="button" class="btn ghost" data-addopt="1">Add option</button>' : ''}
      <label>Explanation <span class="muted small">(shown after answering, optional)</span></label><input data-exp="1" value="${esc(it.explain)}" maxlength="300">`;
  };
  const card = (it, n) => `<div class="task${it._draft ? ' draft' : ''}" data-n="${n}"><div class="task-head"><b>Task ${n + 1}</b><span class="chip">${esc(KIND_LABEL[it.kind])}</span>
    ${it._draft ? '<span class="chip warn">AI draft &mdash; check it</span>' : ''}<span class="grow"></span>
    ${it._draft ? '<button type="button" class="btn" data-act="keep">Keep</button>' : ''}
    <button type="button" class="btn ghost" data-act="up" ${n === 0 ? 'disabled' : ''} aria-label="Move task ${n + 1} up">Up</button>
    <button type="button" class="btn ghost" data-act="down" ${n === items.length - 1 ? 'disabled' : ''} aria-label="Move task ${n + 1} down">Down</button>
    <button type="button" class="btn ghost danger" data-act="del" aria-label="Delete task ${n + 1}">Delete</button></div>${fields(it, n)}</div>`;
  const draw = focusLast => {
    const drafts = items.filter(i => i._draft).length;
    host.innerHTML = `${drafts ? `<div class="draftbar"><b>${drafts} AI draft${drafts > 1 ? 's' : ''} to check.</b>
        <span class="muted small">Read each one, fix anything wrong, then Keep it. Delete the ones you don't want.</span>
        <button type="button" class="btn" data-keepall="1">Keep all</button></div>` : ''}
      ${items.length ? items.map(card).join('') : '<div class="empty" style="margin-bottom:12px">No tasks yet. Add the first one below.</div>'}
      <div class="addbar"><span class="muted small">Add a task:</span>${Object.entries(KIND_LABEL).map(([k, l]) => `<button type="button" class="btn" data-add="${k}">${esc(l)}</button>`).join('')}</div>`;
    if (focusLast) host.querySelector(`.task[data-n="${items.length - 1}"] input`)?.focus();
  };
  const idx = el => +el.closest('.task').dataset.n;
  host.addEventListener('input', e => {
    const t = e.target, it = items[t.closest('.task') ? idx(t) : -1];
    if (!it) return;
    if (t.dataset.f) it[t.dataset.f] = t.value; else if (t.dataset.opt) it.options[+t.dataset.opt] = t.value; else if (t.dataset.exp) it.explain = t.value;
  });
  host.addEventListener('change', e => { const t = e.target; if (t.dataset.correct != null) items[idx(t)].correct = +t.dataset.correct; });
  host.addEventListener('click', e => {
    const b = e.target.closest('button'); if (!b) return;
    if (b.dataset.add) { items.push(blank(b.dataset.add)); return draw(true); }
    if (b.dataset.keepall) { items.forEach(i => delete i._draft); return draw(); }
    if (!b.closest('.task')) return;
    const n = idx(b), it = items[n];
    if (b.dataset.act === 'keep') delete it._draft;
    else if (b.dataset.act === 'del') items.splice(n, 1);
    else if (b.dataset.act === 'up' && n > 0) [items[n - 1], items[n]] = [items[n], items[n - 1]];
    else if (b.dataset.act === 'down' && n < items.length - 1) [items[n + 1], items[n]] = [items[n], items[n + 1]];
    else if (b.dataset.addopt) it.options.push('');
    else if (b.dataset.rmopt != null) { const i = +b.dataset.rmopt; it.options.splice(i, 1); if (it.correct >= it.options.length) it.correct = 0; else if (it.correct > i) it.correct--; }
    else return;
    draw();
  });
  draw();
  return {
    validate() {
      const unchecked = items.filter(i => i._draft).length;
      if (unchecked) return `${unchecked} AI draft${unchecked > 1 ? 's are' : ' is'} still unchecked. Read each one and press Keep, or delete it.`;
      for (const [n, it] of items.entries()) {
        const at = `Task ${n + 1}: `;
        if (it.kind === 'read' && !it.text.trim()) return at + 'type the sentence to read.';
        if (it.kind === 'free' && !it.prompt.trim()) return at + 'type the question.';
        if (it.kind === 'build' && it.answer.trim().split(/\s+/).filter(Boolean).length < 2) return at + 'the sentence needs at least two words.';
        if (QUIZ.includes(it.kind)) {
          if (!(it[stemKey(it)] || '').trim()) return at + (it.kind === 'listen' ? 'type the sentence to be spoken.' : 'type the question.');
          if (it.kind === 'fill' && !it.prompt.includes('___')) return at + 'put ___ where the missing word goes.';
          const opts = it.options.map(o => o.trim());
          if (opts.filter(Boolean).length < 2) return at + 'give at least two answers.';
          if (!opts[it.correct]) return at + 'tick an answer that is not empty as the correct one.';
          if (new Set(opts.filter(Boolean).map(o => o.toLowerCase())).size !== opts.filter(Boolean).length) return at + 'answers must all be different.';
        }
      }
      return null;
    },
    getItems() {
      return items.map(it => {
        if (it.kind === 'read') return { kind: 'read', text: it.text.trim() };
        if (it.kind === 'free') return { kind: 'free', prompt: it.prompt.trim() };
        if (it.kind === 'build') { const words = it.answer.trim().split(/\s+/).filter(Boolean); return { kind: 'build', words, answer: words.join(' ') }; }
        const keep = it.options.map((o, i) => [o.trim(), i]).filter(([o]) => o);
        const out = { kind: it.kind, options: keep.map(([o]) => o), correct: keep.findIndex(([, i]) => i === it.correct) };
        out[stemKey(it)] = it[stemKey(it)].trim();
        if (it.explain.trim()) out.explain = it.explain.trim();
        return out;
      });
    },
    addDrafts(list) { list.forEach(i => items.push({ ...adopt(i), _draft: true })); draw(); },
    get count() { return items.length; },
    get draftCount() { return items.filter(i => i._draft).length; },
  };
}

/* ------------------------------------------------------------------ AI drafting */
function generateDialog(editor, { level = 'A1', topic = '' } = {}) {
  if (!state.health.ai) return toast('AI is not set up. Add your key to vaachak.env and restart the app.');
  const dlg = $('#dialog');
  const types = [['choice', 'Multiple choice'], ['fill', 'Fill in the blank'], ['listen', 'Listen and choose'],
                 ['read', 'Read aloud'], ['free', 'Speak an answer'], ['build', 'Build a sentence']];
  dlg.innerHTML = `<form method="dialog"><h2>Draft tasks with AI</h2>
    <p class="hint" style="margin-bottom:10px">You see everything before it is saved. Nothing reaches your learners until you keep it and save the lesson.</p>
    <label for="g_t">What should the tasks be about?</label>
    <input id="g_t" required maxlength="300" value="${esc(topic)}" placeholder="Using a, an and the; talking about my family; the th sound">
    <div class="row"><div><label for="g_n">How many</label><select id="g_n">${[3, 4, 5, 6, 8, 10].map(n => `<option ${n === 5 ? 'selected' : ''}>${n}</option>`).join('')}</select></div>
      <div><label for="g_l">Level</label><select id="g_l">${['A1', 'A2', 'B1', 'B2'].map(l => `<option ${l === level ? 'selected' : ''}>${l}</option>`).join('')}</select></div></div>
    <label>Kinds of task</label>
    <div class="addbar" id="g_kinds">${types.map(([k, l], i) => `<button type="button" class="btn" data-k="${k}" aria-pressed="${i < 2}">${l}</button>`).join('')}</div>
    <details><summary class="muted small">Paste a passage to build the tasks from (optional)</summary>
      <textarea id="g_c" maxlength="4000" placeholder="Paste a story or paragraph from your textbook"></textarea></details>
    <p class="err" id="g_err" role="alert"></p>
    <div class="actions"><button type="button" class="btn" id="g_cancel">Cancel</button><button class="btn primary" id="g_go">Draft them</button></div></form>`;
  dlg.showModal();
  const picked = new Set(['choice', 'fill']);
  $$('#g_kinds button', dlg).forEach(b => b.onclick = () => {
    const k = b.dataset.k;
    picked.has(k) ? picked.delete(k) : picked.add(k);
    b.setAttribute('aria-pressed', picked.has(k));
  });
  $('#g_cancel', dlg).onclick = () => dlg.close();
  $('form', dlg).onsubmit = async ev => {
    ev.preventDefault();
    const err = $('#g_err', dlg), go = $('#g_go', dlg);
    if (!picked.size) { err.textContent = 'Pick at least one kind of task.'; return; }
    err.textContent = ''; go.disabled = true; go.textContent = 'Writing…';
    try {
      const r = await api('/ai/items', { method: 'POST', body: {
        topic: $('#g_t').value, count: +$('#g_n').value, kinds: [...picked],
        level: $('#g_l').value, context: $('#g_c').value || null } });
      editor.addDrafts(r.items);
      dlg.close();
      toast(r.items.length < r.asked_for
        ? `Drafted ${r.items.length} of ${r.asked_for}. Check each one.`
        : `Drafted ${r.items.length}. Check each one before saving.`);
    } catch (e) { err.textContent = e.message; go.disabled = false; go.textContent = 'Draft them'; }
  };
}

/* ------------------------------------------------------------------ courses list */
async function coursesPage() {
  loading();
  const teacher = state.user.role === 'teacher';
  let q = '', timer;
  const render = async () => {
    const d = await api('/courses?q=' + encodeURIComponent(q));
    const mine = d.mine.map(c => teacher
      ? courseCard(c, `#/course/${c.id}/edit`, `<span class="chip ${c.status === 'published' ? 'good' : 'warn'}">${c.status === 'published' ? 'Published' : 'Draft'}</span><span>${plural(c.learners, 'learner')}</span>`)
      : courseCard(c, `#/course/${c.id}`, meter(c.progress.percent))).join('');
    const avail = d.available.map(c => courseCard(c, `#/course/${c.id}`, `<span>${esc(c.teacher)}</span><span class="chip mark">View</span>`)).join('');
    $('#clist').innerHTML = teacher
      ? (mine ? `<div class="cards">${mine}</div>` : `<div class="empty"><h2>${q ? 'No courses match' : 'Build your first course'}</h2><p>${q ? 'Try a different word.' : 'A course has units, a unit has lessons, and a lesson has teaching notes and tasks. Learners work through it in order and you see their progress.'}</p></div>`)
      : `<h2>My courses</h2>${mine ? `<div class="cards">${mine}</div>` : `<p class="muted">${q ? 'None of your courses match.' : 'You have not started a course yet. Pick one below, or ask your teacher.'}</p>`}
        <h2 style="margin-top:28px">Find a course</h2>${avail ? `<div class="cards">${avail}</div>` : `<p class="muted">${q ? 'No course matches that search.' : 'No other courses are open right now.'}</p>`}`;
  };
  mount(`<div class="row head"><h1>${teacher ? 'Your courses' : 'Courses'}</h1>${teacher ? '<div class="end"><button class="btn primary" id="newcourse">New course</button></div>' : ''}</div>
    <label for="cq" class="sr">Search courses</label><input id="cq" type="search" placeholder="Search by title, topic or level (A1, A2…)" style="margin:6px 0 22px"><div id="clist"></div>`, 'courses');
  $('#cq').oninput = e => { q = e.target.value; clearTimeout(timer); timer = setTimeout(render, 200); };
  $('#newcourse')?.addEventListener('click', newCourseDialog);
  await render();
}

function newCourseDialog() {
  const dlg = $('#dialog');
  dlg.innerHTML = `<form method="dialog"><h2>New course</h2>
    <label for="nt">Title</label><input id="nt" required maxlength="120" placeholder="Spoken English: first steps">
    <label for="ns">What will learners be able to do? (optional)</label><textarea id="ns" maxlength="600"></textarea>
    <div class="row"><div><label for="nl">Level</label><select id="nl">${['A1', 'A2', 'B1', 'B2', 'C1', 'C2'].map(l => `<option>${l}</option>`).join('')}</select></div>
    <div><label for="nv">Who can find it</label><select id="nv"><option value="public">Anyone (listed under Courses)</option><option value="classes">Only classes I give it to</option></select></div></div>
    <label style="display:flex;gap:8px;align-items:center;font-weight:400"><input id="nq" type="checkbox" checked style="width:auto"> Learners finish each lesson before the next one opens</label>
    <p class="err" id="nerr" role="alert"></p><div class="actions"><button type="button" class="btn" id="ncancel">Cancel</button><button class="btn primary">Create course</button></div></form>`;
  dlg.showModal();
  $('#ncancel', dlg).onclick = () => dlg.close();
  $('form', dlg).onsubmit = async ev => {
    ev.preventDefault();
    try {
      const c = await api('/courses', { method: 'POST', body: { title: $('#nt').value, summary: $('#ns').value || null, level: $('#nl').value, visibility: $('#nv').value, sequential: $('#nq').checked } });
      dlg.close(); location.hash = `#/course/${c.id}/edit`;
    } catch (e) { $('#nerr', dlg).textContent = e.message; }
  };
}

/* ------------------------------------------------------------------ learner: course page (the path) */
async function coursePage(id) {
  loading();
  const c = await api('/courses/' + id);
  if (c.mode === 'owner') { location.hash = `#/course/${id}/edit`; return; }
  const p = c.progress, joined = c.enrolled || c.via_class;
  const lessonRow = (l, n) => {
    const inner = `<span class="node ${l.status}" aria-hidden="true">${l.status === 'done' ? '✓' : l.status === 'locked' ? '–' : n}</span>
      <span class="grow"><b>${esc(l.title)}</b><br><span class="muted small">${plural(l.item_count, 'task')}${l.has_recording ? ' · voice note' : ''}${l.status === 'locked' ? ' · finish the lesson before this one' : l.done_items && l.status !== 'done' ? ` · ${l.done_items} of ${l.item_count} done` : ''}</span></span>
      ${l.status === 'done' ? `<span class="stars" aria-label="${l.stars} of 3 stars">${stars(l.stars)}</span>` : l.status === 'open' ? '<span class="chip mark">Open</span>' : '<span class="chip">Locked</span>'}`;
    return l.status === 'locked' ? `<div class="item lesson locked" aria-disabled="true">${inner}</div>` : `<a class="item lesson ${l.status}" href="#/lesson/${l.id}">${inner}</a>`;
  };
  let n = 0;
  mount(`<p><a href="#/courses">← Courses</a></p>
    <div class="classhead band${c.id % 6}"><h1>${esc(c.title)}</h1><p>${esc(c.level)} · ${esc(c.teacher)} · ${plural(c.lessons, 'lesson')}</p>${c.summary ? `<p style="margin-top:10px">${esc(c.summary)}</p>` : ''}</div>
    <div class="panel row" style="align-items:center;margin:14px 0 22px"><div style="flex:3;min-width:220px"><div style="display:flex;gap:10px;align-items:center">${meter(p.percent)}</div>
      <span class="muted small">${p.lessons_done} of ${p.lessons_total} lessons finished${p.avg != null ? ` · average ${p.avg}` : ''}</span></div>
      <div style="flex:0 0 auto">${p.next_lesson_id ? `<button class="btn primary" id="go">${joined || p.lessons_done ? (p.lessons_done ? 'Continue' : 'Start') : 'Start course'}</button>` : p.lessons_total && p.lessons_done === p.lessons_total ? '<span class="chip good">Course finished</span>' : ''}</div></div>
    ${c.units.map(u => `<section style="margin-bottom:24px"><h2>${esc(u.title)}</h2><div class="list">${u.lessons.map(l => lessonRow(l, ++n)).join('') || '<p class="muted">No lessons yet.</p>'}</div></section>`).join('')}
    ${c.enrolled && !c.via_class ? '<p><button class="btn ghost" id="leave">Leave this course</button></p>' : ''}`, 'courses');
  $('#go')?.addEventListener('click', async () => {
    try { if (!joined) await api(`/courses/${id}/enroll`, { method: 'POST' }); location.hash = '#/lesson/' + p.next_lesson_id; } catch (e) { toast(e.message); }
  });
  $('#leave')?.addEventListener('click', async () => { if (confirm('Leave this course? Your results are kept.')) { await api(`/courses/${id}/enroll`, { method: 'DELETE' }); route(); } });
}

/* ------------------------------------------------------------------ learner: lesson */
const voiceNote = rid => `<div class="panel" style="margin-bottom:16px"><b>Your teacher's voice note</b><audio controls preload="metadata" src="${audioUrl('recordings', rid)}" style="width:100%;margin-top:8px"></audio></div>`;

async function lessonPage(id) {
  loading();
  const l = await api('/lessons/' + id);
  if (l.mode === 'owner') { location.hash = `#/lesson/${id}/edit`; return; }
  const intro = `<p class="muted">${esc(l.course.title)} · ${esc(l.unit_title)} · lesson ${l.position} of ${l.lesson_total}</p>
    ${l.intro ? `<div class="panel lesson-note" style="margin-bottom:16px">${esc(l.intro).replace(/\n/g, '<br>')}</div>` : ''}${l.recording_id ? voiceNote(l.recording_id) : ''}`;
  const n = l.items.length;
  runner({
    title: l.title, intro, items: l.items, best: l.best, back: `#/course/${l.course.id}`, backLabel: l.course.title,
    send: (i, fd) => { fd.append('lesson_id', id); fd.append('item_index', i); return api('/attempts', { method: 'POST', form: fd }); },
    finish: scores => {
      const got = Array.from({ length: n }, (_, i) => scores[i]);
      if (got.some(v => v == null)) return '<p class="muted">Answer the other tasks in this lesson to finish it. Use Previous to go back.</p>';
      const avg = Math.round(got.reduce((a, b) => a + b, 0) / n), st = avg >= 90 ? 3 : avg >= 70 ? 2 : 1;
      return `<div class="verdict ok"><b>Lesson finished</b> <span class="stars">${stars(st)}</span> <span>average ${avg}</span>${st < 3 ? '<p class="small">Go back and retry any task to raise your stars.</p>' : ''}</div>
        <p>${l.next_lesson_id ? `<a class="btn primary" href="#/lesson/${l.next_lesson_id}">Next lesson</a> ` : ''}<a class="btn" href="#/course/${l.course.id}">Back to course</a></p>`;
    },
  });
}

/* ------------------------------------------------------------------ learner: personal review */
async function reviewPage() {
  loading();
  const r = await api('/me/review');
  if (!r.items.length) {
    return mount(`<p><a href="#/practice">← Practice</a></p><h1>Your review</h1><div class="empty"><h2>Nothing to review yet</h2>
      <p>When you get a task wrong, or only half right, it shows up here so you can try it again. Do a lesson or a practice set first.</p><a class="btn primary" href="#/courses">Find a course</a></div>`, 'practice');
  }
  runner({
    title: 'Your review', intro: `<p class="muted">${r.items.length} task${r.items.length === 1 ? '' : 's'} you can still improve${r.total_weak > r.items.length ? `, picked from ${r.total_weak}` : ''}. A task leaves this list once you score 80 or more.</p>`,
    items: r.items, back: '#/practice', backLabel: 'Practice',
    send: (i, fd) => { const s = r.items[i].source; for (const [k, v] of Object.entries(s)) fd.append(k, v); return api('/attempts', { method: 'POST', form: fd }); },
    finish: () => '<p><a class="btn primary" href="#/review">Review again</a> <a class="btn" href="#/practice">Back to practice</a></p>',
  });
}

/* ------------------------------------------------------------------ teacher: course builder */
async function courseBuilder(id, tab) {
  loading();
  const c = await api('/courses/' + id);
  if (c.mode !== 'owner') { location.hash = '#/course/' + id; return; }
  const published = c.status === 'published';
  const head = `<p><a href="#/courses">← Courses</a></p>
    <div class="row head"><div><h1 style="margin:0">${esc(c.title)}</h1><p class="muted" style="margin:2px 0 0">${esc(c.level)} · ${plural(c.units.length, 'unit')} · ${plural(c.lessons, 'lesson')} · <span class="chip ${published ? 'good' : 'warn'}">${published ? 'Published' : 'Draft'}</span></p></div>
      <div class="end"><button class="btn ${published ? '' : 'primary'}" id="publish">${published ? 'Unpublish' : 'Publish'}</button></div></div>
    <div class="tabs"><a href="#/course/${id}/edit" ${tab === 'edit' ? 'aria-current="page"' : ''}>Build</a><a href="#/course/${id}/learners" ${tab === 'learners' ? 'aria-current="page"' : ''}>Learners</a></div>`;
  let body = '';
  if (tab === 'learners') body = await learnersTab(id);
  else {
    const myClasses = await api('/classes');
    const free = myClasses.filter(k => !c.classes.some(x => x.id === k.id));
    body = `<details class="panel" id="details"><summary><b>Course details</b></summary>
        <label for="d_t">Title</label><input id="d_t" value="${esc(c.title)}" maxlength="120">
        <label for="d_s">Summary</label><textarea id="d_s" maxlength="600">${esc(c.summary || '')}</textarea>
        <div class="row"><div><label for="d_l">Level</label><select id="d_l">${['A1', 'A2', 'B1', 'B2', 'C1', 'C2'].map(l => `<option ${l === c.level ? 'selected' : ''}>${l}</option>`).join('')}</select></div>
        <div><label for="d_v">Who can find it</label><select id="d_v"><option value="public" ${c.visibility === 'public' ? 'selected' : ''}>Anyone (listed under Courses)</option><option value="classes" ${c.visibility === 'classes' ? 'selected' : ''}>Only classes I give it to</option></select></div></div>
        <label style="display:flex;gap:8px;align-items:center;font-weight:400"><input id="d_q" type="checkbox" style="width:auto" ${c.sequential ? 'checked' : ''}> Learners finish each lesson before the next one opens</label>
        <p class="actions" style="justify-content:flex-start"><button class="btn primary" id="d_save">Save details</button><button class="btn ghost danger" id="d_del">Delete course</button></p></details>
      <h2 style="margin-top:26px">Content</h2>
      ${c.units.map(u => `<section class="unit panel" data-unit="${u.id}">
        <div class="unit-head"><input class="unit-title" data-utitle="${u.id}" value="${esc(u.title)}" maxlength="120" aria-label="Unit title">
          <button class="btn ghost" data-umove="up" data-id="${u.id}" aria-label="Move unit up">Up</button><button class="btn ghost" data-umove="down" data-id="${u.id}" aria-label="Move unit down">Down</button>
          <button class="btn ghost danger" data-udel="${u.id}">Delete unit</button></div>
        <div class="list" style="margin:12px 0">${u.lessons.map(l => `<div class="item"><a class="grow" href="#/lesson/${l.id}/edit" style="text-decoration:none;color:inherit"><h3>${esc(l.title)}</h3>
          <span class="muted small">${plural(l.item_count, 'task')}${l.has_recording ? ' · voice note' : ''}</span></a>${l.item_count ? '' : '<span class="chip warn">No tasks</span>'}
          <a class="btn" href="#/lesson/${l.id}/edit">Edit</a><button class="btn ghost" data-lmove="up" data-id="${l.id}" aria-label="Move ${esc(l.title)} up">Up</button><button class="btn ghost" data-lmove="down" data-id="${l.id}" aria-label="Move ${esc(l.title)} down">Down</button>
          <button class="btn ghost danger" data-ldel="${l.id}" aria-label="Delete ${esc(l.title)}">Delete</button></div>`).join('') || '<p class="muted" style="margin:0">No lessons in this unit yet.</p>'}</div>
        <form class="inline" data-addlesson="${u.id}"><input placeholder="New lesson title" required maxlength="120" aria-label="New lesson title"><button class="btn">Add lesson</button></form></section>`).join('')}
      <form class="panel inline" id="addunit"><input placeholder="${c.units.length ? 'Next unit title' : 'First unit title, for example Greetings'}" required maxlength="120" aria-label="New unit title"><button class="btn primary">Add unit</button></form>
      <h2 style="margin-top:26px">Classes using this course</h2>
      ${published ? `${c.classes.length ? `<div class="list" style="margin-bottom:12px">${c.classes.map(k => `<div class="item"><span class="grow"><b>${esc(k.name)}</b></span><button class="btn ghost danger" data-unassign="${k.id}">Remove</button></div>`).join('')}</div>` : '<p class="muted">No class has this course yet.</p>'}
        ${free.length ? `<form class="inline" id="assign"><select id="a_class" aria-label="Class">${free.map(k => `<option value="${k.id}">${esc(k.name)}</option>`).join('')}</select><button class="btn primary">Give to class</button></form>` : '<p class="muted small">All your classes already have it, or you have no classes yet.</p>'}`
        : '<p class="muted">Publish the course to give it to a class.</p>'}`;
  }
  mount(head + body, 'courses');
  $('#publish').onclick = async () => {
    try { await api(`/courses/${id}/publish`, { method: 'POST', body: { published: !published } }); toast(published ? 'Unpublished' : 'Published'); route(); } catch (e) { toast(e.message); }
  };
  if (tab === 'learners') return;
  $('#d_save').onclick = async () => {
    try { await api('/courses/' + id, { method: 'PATCH', body: { title: $('#d_t').value, summary: $('#d_s').value, level: $('#d_l').value, visibility: $('#d_v').value, sequential: $('#d_q').checked } }); toast('Saved'); route(); } catch (e) { toast(e.message); }
  };
  $('#d_del').onclick = async () => { if (confirm('Delete this course, its lessons and every learner result? This cannot be undone.')) { await api('/courses/' + id, { method: 'DELETE' }); location.hash = '#/courses'; } };
  $$('[data-utitle]').forEach(i => i.onchange = async () => { try { await api('/units/' + i.dataset.utitle, { method: 'PATCH', body: { title: i.value } }); toast('Saved'); } catch (e) { toast(e.message); } });
  const act = (sel, fn) => $$(sel).forEach(b => b.onclick = async () => { try { await fn(b); await keepScroll(route); } catch (e) { if (e.message !== 'Cancelled') toast(e.message); } });
  act('[data-umove]', b => api(`/units/${b.dataset.id}/move`, { method: 'POST', body: { direction: b.dataset.umove } }));
  act('[data-lmove]', b => api(`/lessons/${b.dataset.id}/move`, { method: 'POST', body: { direction: b.dataset.lmove } }));
  act('[data-udel]', async b => { if (!confirm('Delete this unit and all its lessons?')) throw new Error('Cancelled'); await api('/units/' + b.dataset.udel, { method: 'DELETE' }); });
  act('[data-ldel]', async b => { if (!confirm('Delete this lesson and learner results for it?')) throw new Error('Cancelled'); await api('/lessons/' + b.dataset.ldel, { method: 'DELETE' }); });
  act('[data-unassign]', b => api(`/classes/${b.dataset.unassign}/courses/${id}`, { method: 'DELETE' }));
  $$('[data-addlesson]').forEach(f => f.onsubmit = async ev => {
    ev.preventDefault();
    try { const l = await api(`/units/${f.dataset.addlesson}/lessons`, { method: 'POST', body: { title: $('input', f).value, items: [] } }); location.hash = `#/lesson/${l.id}/edit`; } catch (e) { toast(e.message); }
  });
  $('#addunit').onsubmit = async ev => { ev.preventDefault(); try { await api(`/courses/${id}/units`, { method: 'POST', body: { title: $('#addunit input').value } }); await keepScroll(route); } catch (e) { toast(e.message); } };
  $('#assign')?.addEventListener('submit', async ev => {
    ev.preventDefault();
    try { await api(`/classes/${$('#a_class').value}/courses`, { method: 'POST', body: { course_id: +id } }); toast('Given to class'); await keepScroll(route); } catch (e) { toast(e.message); }
  });
}

async function learnersTab(id) {
  const p = await api(`/courses/${id}/progress`);
  if (!p.learners.length) return '<div class="empty"><h2>No learners yet</h2><p>Give the course to a class, or publish it as public so self-learners can start it. Their progress shows here.</p></div>';
  return `<div class="scroll panel" style="padding:0"><table><thead><tr><th>Learner</th><th>Class</th><th style="min-width:160px">Progress</th><th>Lessons</th><th>Average</th><th>Active</th></tr></thead><tbody>
    ${p.learners.map(l => `<tr><td><b>${esc(l.name)}</b> ${l.needs_help ? '<span class="chip bad">Needs help</span>' : ''}</td><td class="muted">${esc(l.classes.join(', ') || 'Self-enrolled')}</td>
      <td><div style="display:flex;gap:8px;align-items:center">${meter(l.percent)}</div></td><td>${l.lessons_done} of ${l.lessons_total}</td><td>${l.avg ?? '–'}</td><td class="muted">${ago(l.last_active)}</td></tr>`).join('')}</tbody></table></div>
    <h2 style="margin-top:26px">Lesson by lesson</h2><div class="list">${p.lessons.map(l => `<div class="item"><span class="grow">${esc(l.title)}</span><span class="chip">${l.completed} of ${p.learners.length} finished</span><span class="chip">${l.avg == null ? 'no average yet' : 'average ' + l.avg}</span></div>`).join('')}</div>`;
}

/* ------------------------------------------------------------------ teacher: lesson editor */
async function lessonEditor(id) {
  loading();
  const l = await api('/lessons/' + id);
  if (l.mode !== 'owner') { location.hash = '#/lesson/' + id; return; }
  let recId = l.recording_id, clip = null, recording = false, timer;
  const rec = makeRecorder();
  mount(`<p><a href="#/course/${l.course.id}/edit">← ${esc(l.course.title)}</a></p><h1>Edit lesson</h1><p class="muted">${esc(l.unit_title)}</p>
    <div class="panel"><label for="l_t" style="margin-top:0">Lesson title</label><input id="l_t" value="${esc(l.title)}" maxlength="120">
      <label for="l_i">Teaching note</label><textarea id="l_i" maxlength="2000" placeholder="Explain the idea in a few lines. Learners read this before the tasks.">${esc(l.intro || '')}</textarea>
      <label>Voice note <span class="muted small">(optional)</span></label>
      <div id="vn">${recId ? `<audio controls preload="metadata" src="${audioUrl('recordings', recId)}" style="width:100%"></audio>` : ''}</div>
      <div class="say" style="margin-top:8px"><button type="button" class="btn rec" id="vrec">● ${recId ? 'Record again' : 'Record'}</button><span class="muted" id="vtime"></span>${recId ? '<button type="button" class="btn ghost danger" id="vrm">Remove voice note</button>' : ''}</div>
      <p class="hint">Recorded in your browser and saved with the lesson when you press Save.</p></div>
    <div class="row head" style="margin-top:26px"><h2 style="margin:0">Tasks</h2>
      <div class="end">${state.health.ai ? '<button class="btn primary" id="gen">Draft tasks with AI</button>' : '<span class="muted small">Add your AI key to draft tasks automatically</span>'}</div></div>
    <div id="itemed"></div>
    <p class="err" id="lerr" role="alert"></p>
    <p class="actions" style="justify-content:flex-start"><button class="btn primary" id="lsave">Save lesson</button><a class="btn" href="#/course/${l.course.id}/edit">Back to course</a></p>`, 'courses');
  const editor = makeItemEditor($('#itemed'), l.items);
  $('#gen')?.addEventListener('click', () => generateDialog(editor, { topic: l.title }));
  $('#vrec').onclick = async () => {
    const btn = $('#vrec');
    if (!recording) {
      try { await rec.start(); } catch { return toast('Microphone is blocked. Allow it in the browser address bar.'); }
      recording = true; btn.textContent = '■ Stop'; btn.classList.add('live'); const t0 = Date.now();
      timer = setInterval(() => { const s = Math.floor((Date.now() - t0) / 1000); $('#vtime').textContent = `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`; if (s >= 300) btn.click(); }, 250);
    } else {
      clearInterval(timer); recording = false; btn.classList.remove('live'); btn.textContent = '● Record again';
      const c = await rec.stop();
      if (c.duration < 1000) return toast('That was too short. Record at least one second.');
      clip = c; $('#vn').innerHTML = `<audio controls src="${URL.createObjectURL(c.blob)}" style="width:100%"></audio>`;
      fixAudioDuration($('#vn'));
    }
  };
  $('#vrm')?.addEventListener('click', () => { recId = null; clip = null; $('#vn').innerHTML = ''; $('#vrm').remove(); toast('Voice note removed. Save to keep the change.'); });
  $('#lsave').onclick = async () => {
    const err = $('#lerr'), btn = $('#lsave'); err.textContent = '';
    if (recording) return toast('Stop the recording first.');
    const bad = editor.validate(); if (bad) { err.textContent = bad; return; }
    btn.disabled = true;
    try {
      if (clip) {
        const f = new FormData(); f.append('title', $('#l_t').value + ' voice note'); f.append('duration_ms', Math.round(clip.duration));
        f.append('file', clip.blob, 'lesson.' + (clip.blob.type.split('/')[1] || 'webm'));
        recId = (await api('/recordings', { method: 'POST', form: f })).id; clip = null;
      }
      await api('/lessons/' + id, { method: 'PUT', body: { title: $('#l_t').value, intro: $('#l_i').value || null, recording_id: recId, items: editor.getItems() } });
      toast('Lesson saved');
    } catch (e) { err.textContent = e.message; } finally { btn.disabled = false; }
  };
}

/* ------------------------------------------------------------------ class: courses tab */
async function classCoursesTab(c, t) {
  const rows = await api(`/classes/${c.id}/courses`);
  if (!t) {
    return rows.length ? `<div class="list">${rows.map(x => `<a class="item" href="#/course/${x.id}"><div class="grow"><h3>${esc(x.title)}</h3><span class="muted small">${esc(x.level)} · ${plural(x.lessons, 'lesson')}</span></div><div style="width:160px;display:flex;gap:8px;align-items:center">${meter(x.progress.percent)}</div></a>`).join('')}</div>`
      : '<div class="empty"><h2>No course yet</h2><p>Your teacher has not given this class a course. You can find open courses under Courses.</p><a class="btn" href="#/courses">Browse courses</a></div>';
  }
  const mine = (await api('/courses')).mine.filter(x => x.status === 'published' && !rows.some(r => r.id === x.id));
  return `${rows.length ? `<div class="list" style="margin-bottom:18px">${rows.map(x => `<div class="item"><div class="grow"><h3>${esc(x.title)}</h3><span class="muted small">${esc(x.level)} · ${plural(x.lessons, 'lesson')} · class average ${x.class_percent ?? 0}% finished</span></div>
      <a class="btn" href="#/course/${x.id}/learners">Progress</a><button class="btn ghost danger" data-unassign="${x.id}">Remove</button></div>`).join('')}</div>` : '<div class="empty" style="margin-bottom:18px"><h2>No course yet</h2><p>Give this class one of your published courses. Learners then see it under Courses.</p></div>'}
    ${mine.length ? `<form class="inline" id="giveform"><select id="give" aria-label="Course to give">${mine.map(x => `<option value="${x.id}">${esc(x.title)}</option>`).join('')}</select><button class="btn primary">Give course</button></form>`
      : '<p class="muted">You have no other published course. <a href="#/courses">Build or publish one</a>.</p>'}`;
}
function bindClassCourses(c) {
  $('#giveform')?.addEventListener('submit', async ev => {
    ev.preventDefault();
    try { await api(`/classes/${c.id}/courses`, { method: 'POST', body: { course_id: +$('#give').value } }); toast('Course given to the class'); route(); } catch (e) { toast(e.message); }
  });
  $$('[data-unassign]').forEach(b => b.onclick = async () => { if (confirm('Take this course away from the class? Results are kept.')) { await api(`/classes/${c.id}/courses/${b.dataset.unassign}`, { method: 'DELETE' }); route(); } });
}


/* ------------------------------------------------------------------ teacher: who needs you */
const REASON_ICON = { never_started: '!', inactive: '…', quiet: '·', stuck_skill: '!', declining: '↓', below_proficient: '!' };

async function attentionTab(c) {
  const d = await api(`/classes/${c.id}/attention`);
  if (!d.rows.length) {
    return `<div class="empty"><h2>Nobody needs chasing</h2>
      <p>Everyone in this class is active and getting on. Come back after the next few answers.</p></div>`;
  }
  const row = r => `<div class="item attn sev${r.severity}" data-row="${r.student_id}|${r.reason}">
    <span class="grow"><b>${esc(r.name)}</b><br><span class="muted small">${esc(r.why)}${r.last_active ? ' · last seen ' + ago(r.last_active).toLowerCase() : ''}</span></span>
    <button class="btn primary" data-do="${r.action}" data-sid="${r.student_id}" data-skill="${esc(r.detail.skill || '')}" data-label="${esc(r.detail.label || '')}">${esc(r.action_label)}</button>
    <button class="btn ghost" data-drop="${r.student_id}|${r.reason}" title="Stop showing me this">Not useful</button></div>`;
  return `<p class="muted">${d.rows.length} thing${d.rows.length > 1 ? 's' : ''} to look at, most urgent first. Each one has a single next step.</p>
    <div class="list">${d.rows.map(row).join('')}</div>`;
}

function bindAttention(c) {
  $$('[data-drop]').forEach(b => b.onclick = async () => {
    const [student_id, reason] = b.dataset.drop.split('|');
    try { await api(`/classes/${c.id}/attention/dismiss`, { method: 'POST', body: { student_id: +student_id, reason } }); route(); }
    catch (e) { toast(e.message); }
  });
  $$('[data-do]').forEach(b => b.onclick = async () => {
    const sid = +b.dataset.sid;
    if (b.dataset.do === 'review') { location.hash = `#/class/${c.id}/student/${sid}`; return; }
    const roster = (await api(`/classes/${c.id}`)).roster;
    const student = roster.find(r => r.id === sid);
    if (!student) return toast('That learner is no longer in the class.');
    assignmentDialog(c, student, { topic: b.dataset.label || '', title: b.dataset.label ? `Practice: ${b.dataset.label}` : '' });
  });
}

async function skillGridTab(c) {
  const g = await api(`/classes/${c.id}/skill-grid`);
  if (!g.skills.length) {
    return `<div class="empty"><h2>Nothing to show yet</h2><p>Once learners answer a few tasks, the skills they get wrong appear here.</p></div>`;
  }
  const cell = n => n === 0 ? '<td class="ok">·</td>' : `<td class="miss m${Math.min(n, 4)}">${n}</td>`;
  return `<p class="muted">How many times each learner got a skill wrong. Bigger numbers are where to teach next.</p>
    <div class="scroll panel" style="padding:0"><table class="grid"><thead><tr><th>Learner</th>
      ${g.skills.map(s => `<th title="${esc(s.hint)}">${esc(s.label)}</th>`).join('')}</tr></thead><tbody>
      ${g.rows.map(r => `<tr><td><b>${esc(r.name)}</b></td>${r.counts.map(cell).join('')}</tr>`).join('')}
      <tr class="totals"><td>Whole class</td>${g.skills.map(s => `<td>${s.total}</td>`).join('')}</tr>
    </tbody></table></div>`;
}


/* ------------------------------------------------------------------ learner: Today */
async function todayPage() {
  loading();
  const [stats, review, courses] = await Promise.all([
    api('/me/stats'), api('/me/review'), api('/courses'),
  ]);
  const course = courses.mine.find(c => c.progress && c.progress.next_lesson_id);
  const name = (state.user.name || '').split(' ')[0];

  // One main thing to do, chosen for them, so nobody has to pick from a menu.
  let main;
  if (review.items.length) {
    main = { href: '#/review', title: `Go over ${plural(review.items.length, 'thing')} again`,
             sub: 'These are the ones you got wrong before. Getting them right now is what makes them stick.', cta: 'Start review' };
  } else if (course) {
    main = { href: '#/lesson/' + course.progress.next_lesson_id, title: `Carry on with ${course.title}`,
             sub: `${course.progress.lessons_done} of ${course.progress.lessons_total} lessons done.`, cta: 'Next lesson' };
  } else if (courses.available.length) {
    const c = courses.available[0];
    main = { href: '#/course/' + c.id, title: `Start ${c.title}`, sub: c.summary || 'A course you can begin today.', cta: 'Open course' };
  } else {
    main = { href: '#/practice', title: 'Do a few minutes of speaking', sub: 'Pick any set and talk. You get feedback after every answer.', cta: 'Start practising' };
  }

  const weak = (stats.weak_skills || []).filter(w => !w.accent_only);
  const done = stats.days ? stats.days.slice(-7).filter(d => d.attempts).length : 0;
  mount(`<h1>${name ? esc(name) + ', here is today' : 'Here is today'}</h1>
    <a class="hero" href="${main.href}"><div><h2>${esc(main.title)}</h2><p>${esc(main.sub)}</p></div>
      <span class="btn primary">${esc(main.cta)}</span></a>
    <div class="cols" style="margin-top:26px"><div>
      ${weak.length ? `<h2>What to work on</h2>
        <div class="list">${weak.map(w => `<div class="item"><span class="grow"><b>${esc(w.label)}</b><br><span class="muted small">${esc(w.hint)} · got it wrong ${plural(w.misses, 'time')}</span></span>
          <a class="btn" href="#/review">Practise this</a></div>`).join('')}</div>`
        : '<h2>What to work on</h2><p class="muted">Nothing is going wrong often enough to call out yet. Keep speaking and this fills in.</p>'}
      ${stats.classes && stats.classes.length ? `<h2 style="margin-top:24px">Your classes</h2><div class="list">${stats.classes.map(c => `<a class="item" href="#/class/${c.id}/work"><span class="grow"><b>${esc(c.name)}</b></span><span class="chip ${c.completed === c.assignments && c.assignments ? 'good' : ''}">${c.completed} of ${c.assignments} done</span></a>`).join('')}</div>` : ''}
    </div><aside>
      <h2>This week</h2>
      <div class="week" role="img" aria-label="You practised on ${done} of the last 7 days">
        ${(stats.days || []).slice(-7).map(d => `<span class="${d.attempts ? 'on' : ''}" title="${d.day}"></span>`).join('')}</div>
      <p class="muted small">${done ? `You spoke on ${plural(done, 'day')} this week.` : 'No speaking yet this week. One short go is enough to start.'}</p>
      ${stats.attempts ? `<p class="muted small">${plural(stats.attempts, 'answer')} so far · average ${stats.avg_score}</p>
        <p><a class="btn ghost" href="#/progress">See all my progress</a></p>` : ''}
    </aside></div>`, 'today');
}
