import { api, session, saveSession } from "./api.js?v=demo3";
import { createAudioScope, mountRecorder } from "./audio.js?v=demo3";
import {
  completionChart,
  trendPanel,
  bindTrend,
  simpleReadingFeedback,
} from "./insights.js";

const app = document.querySelector("#app");
const modal = document.querySelector("#modal");
let scope = createAudioScope(),
  routeVersion = 0,
  routeTimers = [],
  authRole = "teacher",
  authMode = "login",
  authRenderVersion = 0;
let navigationCleanup = () => {},
  closeNavigation = () => {};
const E = (value) =>
  String(value ?? "").replace(
    /[&<>"']/g,
    (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[
        c
      ],
  );
const A = (value) => (Array.isArray(value) ? value : []);
const pct = (value) =>
  typeof value === "number" && Number.isFinite(value)
    ? `${Math.round(value * 100)}%`
    : "—";
const date = (value) => {
  if (!value) return "—";
  const d = new Date(
    value.endsWith?.("Z") || /[+-]\d\d:\d\d$/.test(value) ? value : `${value}Z`,
  );
  return Number.isNaN(d.getTime())
    ? "—"
    : d.toLocaleDateString(undefined, {
        day: "numeric",
        month: "short",
        year: "numeric",
      });
};
const initials = (name) =>
  String(name || "V")
    .split(/[\s@]+/)
    .slice(0, 2)
    .map((part) => part[0])
    .join("")
    .toUpperCase();
const kindName = (kind) =>
  ({
    read_aloud: "Read aloud",
    choice: "Word quiz",
    matching: "Matching",
    meaning: "Meaning",
  })[kind] ||
  kind ||
  "Practice";
const skillName = (skill) =>
  ({
    read_aloud: "Words read",
    pronunciation: "Pronunciation",
    synonym: "Synonyms",
    antonym: "Antonyms",
    vocabulary: "Vocabulary",
    meaning: "Understanding meaning",
  })[skill] || String(skill || "Practice").replaceAll("_", " ");
const shortId = (id) =>
  String(id || "")
    .slice(0, 8)
    .toUpperCase();
const paths = {
  grid: '<rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/>',
  class:
    '<path d="M3 21V7l9-4 9 4v14M8 21v-5h8v5M7 9h1m8 0h1M7 12h1m8 0h1M1 21h22"/>',
  users:
    '<path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2m20 0v-2a4 4 0 0 0-3-3.87M16 3.13a4 4 0 0 1 0 7.75"/><circle cx="9" cy="7" r="4"/>',
  book: '<path d="M12 5c-3-2-7-2-10-1v15c4-1 7-1 10 1 3-2 6-2 10-1V4c-3-1-7-1-10 1Zm0 0v15"/>',
  clipboard:
    '<rect x="5" y="4" width="14" height="18" rx="2"/><rect x="9" y="2" width="6" height="4" rx="1"/><path d="M9 11h6m-6 4h6"/>',
  mic: '<rect x="9" y="2" width="6" height="13" rx="3"/><path d="M5 10v2a7 7 0 0 0 14 0v-2m-7 9v3m-4 0h8"/>',
  arrow: '<path d="M5 12h14m-5-5 5 5-5 5"/>',
  back: '<path d="M19 12H5m5-5-5 5 5 5"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  check: '<path d="m5 12 4 4L19 6"/>',
  checkcircle: '<circle cx="12" cy="12" r="9"/><path d="m8 12 3 3 5-6"/>',
  clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
  leaf: '<path d="M20 4C8 0 1 9 6 16s16 2 14-12ZM5 21 16 9m-5 5h6m-6 0v-4"/>',
  chart: '<path d="M4 3v18h17M8 16v-4m5 4V8m5 8V5"/>',
  logout: '<path d="M10 17v4H3V3h7v4m-2 5h13m-4-4 4 4-4 4"/>',
  search: '<circle cx="10.5" cy="10.5" r="6.5"/><path d="m16 16 5 5"/>',
  close: '<path d="m6 6 12 12M6 18 18 6"/>',
  match:
    '<rect x="3" y="3" width="6" height="6" rx="1"/><rect x="15" y="15" width="6" height="6" rx="1"/><path d="M15 6h6M3 18h6M7 9l10 6"/>',
  message:
    '<path d="M21 11a9 9 0 0 1-9 9 10 10 0 0 1-4-.8L3 21l1.8-5A9 9 0 1 1 21 11Z"/><path d="M8 9h8m-8 4h5"/>',
  menu: '<path d="M4 6h16M4 12h16M4 18h16"/>',
  sound:
    '<path d="M11 5 6 9H2v6h4l5 4V5Zm4 3a6 6 0 0 1 0 8m3-11a10 10 0 0 1 0 14"/>',
  shield:
    '<path d="m12 2 9 4v6c0 5-9 10-9 10S3 17 3 12V6l9-4Z"/><path d="m8 12 3 3 5-6"/>',
  quiz: '<rect x="4" y="3" width="16" height="18" rx="2"/><path d="m8 8 1 1 2-2m2 2h3m-8 6h3m2 0h3"/>',
};
function icon(name, size = 18) {
  return `<svg width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${paths[name] || paths.book}</svg>`;
}
const kindIcon = (kind) =>
  ({
    read_aloud: "mic",
    choice: "quiz",
    matching: "match",
    meaning: "message",
  })[kind] || "book";
const brand = () =>
  '<div class="brand"><span class="brandmark">V</span><span>vachak<span class="ai">AI</span></span></div>';
const badge = (kind) =>
  `<span class="badge type-${E(kind)}">${kindName(kind)}</span>`;
function statusBadge(status) {
  return `<span class="badge ${{ completed: "green", pending: "amber", needs_review: "amber", failed: "red" }[status] || "gray"}">${E({ completed: "Completed", pending: "Analyzing", needs_review: "Teacher review", failed: "Analysis unavailable" }[status] || status || "Not started")}</span>`;
}
const art = () =>
  '<svg viewBox="0 0 200 170" fill="none" xmlns="http://www.w3.org/2000/svg" aria-hidden="true"><circle cx="100" cy="85" r="68" stroke="currentColor" opacity=".14"/><circle cx="100" cy="85" r="48" stroke="currentColor" opacity=".2"/><path d="M31 85h5m9-14v28m10-45v62m10-41v20m10-49v78m10-67v56m10-81v106m10-82v58m10-46v34m10-65v96m10-63v30m10-41v52m10-36v20m10-13h5" stroke="currentColor" stroke-width="5" stroke-linecap="round"/><path d="m164 26 3 7 7 3-7 3-3 7-3-7-7-3 7-3 3-7ZM35 127l2 5 5 2-5 2-2 5-2-5-5-2 5-2 2-5Z" fill="currentColor"/></svg>';
function toast(message, error = false) {
  const el = document.createElement("div");
  el.className = `toast${error ? " error" : ""}`;
  el.textContent = message;
  document.querySelector("#toast-region").append(el);
  setTimeout(() => el.remove(), 6000);
}
function go(path) {
  if (location.hash === `#/${path}`) route();
  else location.hash = `#/${path}`;
}
function empty(title, text, action = "", compact = false, symbol = "book") {
  return `<div class="empty${compact ? " compact" : ""}"><div class="empty-icon">${icon(symbol, 25)}</div><h3>${E(title)}</h3><p>${E(text)}</p>${action}</div>`;
}
const linkButton = (path, text, style = "primary", symbol = "") =>
  `<a class="button button-${style}" href="#/${path}">${symbol ? icon(symbol, 15) : ""}${E(text)}</a>`;
function heading(title, subtitle, action = "", eyebrow = "") {
  return `<div class="page-heading"><div>${eyebrow ? `<div class="eyebrow">${E(eyebrow)}</div>` : ""}<h1>${E(title)}</h1><p>${E(subtitle)}</p></div>${action}</div>`;
}
function stat(label, value, symbol, note = "") {
  return `<div class="stat"><div><div class="stat-label">${E(label)}</div><div class="stat-value">${E(value ?? 0)}</div>${note ? `<div class="stat-note">${E(note)}</div>` : ""}</div><div class="stat-icon">${icon(symbol, 18)}</div></div>`;
}
const audioPlayer = (url, label = "Audio recording") =>
  `<div class="audio-wrap" data-audio-url="${E(url)}" data-label="${E(label)}"><span class="audio-loading">${icon("sound", 14)} Loading recording…</span></div>`;
function formError(form, message) {
  const el = form.querySelector(".form-error");
  el.textContent = message;
  if (message) el.scrollIntoView({ block: "nearest", behavior: "smooth" });
}
function busy(form, state, text) {
  const btn = form.querySelector("[type=submit]");
  if (btn) {
    if (state) btn.dataset.original = btn.textContent;
    btn.disabled = state;
    if (text) btn.textContent = text;
    else if (!state && btn.dataset.original)
      btn.textContent = btn.dataset.original;
  }
}
const controlLocks = new WeakMap();
function lockEditing(form, state) {
  form
    .querySelectorAll("input,select,textarea,button:not([type=submit])")
    .forEach((control) => {
      if (state) {
        controlLocks.set(control, control.disabled);
        control.disabled = true;
      } else if (controlLocks.has(control)) {
        control.disabled = controlLocks.get(control);
        controlLocks.delete(control);
      }
    });
}
const liveModalForm = (form) =>
  modal.open && form.isConnected && modal.contains(form);
function openModal(title, subtitle, body, onMount) {
  modal.innerHTML = `<div class="modal-heading"><div><h2>${E(title)}</h2>${subtitle ? `<p>${E(subtitle)}</p>` : ""}</div><button type="button" class="icon-button" data-close aria-label="Close dialog">${icon("close")}</button></div>${body}`;
  modal.querySelector("[data-close]").onclick = () => modal.close();
  modal.showModal();
  onMount?.(modal);
}
function cleanup() {
  scope.dispose();
  scope = createAudioScope();
  routeTimers.forEach(clearTimeout);
  routeTimers = [];
  if (modal.open) modal.close();
}
function shell() {
  navigationCleanup();
  const user = session().user,
    teacher = user.role === "teacher";
  const nav = teacher
    ? [
        ["overview", "grid", "Overview"],
        ["classrooms", "class", "My classrooms"],
        ["problems", "book", "Problem library"],
        ["assignments", "clipboard", "Assignments"],
        ["progress", "chart", "Student progress"],
        ["profile", "leaf", "Learning profile"],
      ]
    : [
        ["overview", "grid", "My learning"],
        ["assignments", "clipboard", "My assignments"],
        ["history", "chart", "My progress"],
        ["profile", "leaf", "Learning profile"],
      ];
  app.innerHTML = `<div class="app-shell"><div class="mobile-scrim"></div><aside class="sidebar">${brand()}<div class="nav-caption">${teacher ? "Teacher workspace" : "Student workspace"}</div><nav class="nav" aria-label="Main navigation">${nav.map(([path, symbol, name]) => `<a class="nav-link" href="#/${path}" data-nav="${path}">${icon(symbol)}<span>${name}</span></a>`).join("")}</nav><div class="sidebar-note"><div class="note-symbol">${icon("leaf", 21)}</div><h4>A little practice. A lot of growth.</h4><p>${teacher ? "Your voice guides their next step. Make every practice personal." : "Find your pace, try again, and let your voice grow."}</p></div><div class="sidebar-footer"><span class="avatar">${E(initials(user.display_name))}</span><div class="identity"><strong>${E(user.display_name)}</strong><span>${teacher ? "Teacher account" : "Student account"}</span></div><button class="icon-button" data-logout aria-label="Sign out" title="Sign out">${icon("logout", 17)}</button></div></aside><div class="main-wrap"><header class="topbar"><button class="icon-button mobile-toggle" aria-label="Open navigation">${icon("menu", 20)}</button><div class="topbar-path"><span>${teacher ? "Teacher workspace" : "My workspace"}</span><span>/</span><strong id="breadcrumb">Overview</strong></div><div class="topbar-date">${icon("leaf", 14)} A space to learn, one word at a time</div></header><main class="content" id="content" tabindex="-1"></main></div></div>`;
  app.querySelector("[data-logout]").onclick = () => {
    const revocation = api("/auth/logout", { method: "POST" });
    saveSession(null);
    cleanup();
    go("login");
    revocation.catch(() => {
      /* Local sign-out already cleared the private workspace. */
    });
  };
  const sidebar = app.querySelector(".sidebar"),
    scrim = app.querySelector(".mobile-scrim"),
    toggle = app.querySelector(".mobile-toggle"),
    main = app.querySelector(".main-wrap"),
    mobile = window.matchMedia("(max-width: 680px)");
  sidebar.id = "workspace-navigation";
  sidebar.insertAdjacentHTML(
    "afterbegin",
    `<button type="button" class="icon-button sidebar-close" aria-label="Close navigation">${icon("close", 20)}</button>`,
  );
  toggle.setAttribute("aria-controls", sidebar.id);
  scrim.setAttribute("aria-hidden", "true");
  let opened = false;
  const focusable = () =>
    [...sidebar.querySelectorAll("a[href],button:not([disabled])")].filter(
      (element) => element.getClientRects().length,
    );
  const setOpen = (value, restoreFocus = true) => {
    const wasOpen = opened;
    opened = Boolean(value && mobile.matches);
    sidebar.classList.toggle("mobile-open", opened);
    scrim.classList.toggle("visible", opened);
    sidebar.inert = mobile.matches && !opened;
    main.inert = opened;
    toggle.setAttribute("aria-expanded", String(opened));
    toggle.setAttribute(
      "aria-label",
      opened ? "Close navigation" : "Open navigation",
    );
    document.body.style.overflow = opened ? "hidden" : "";
    if (mobile.matches) {
      sidebar.setAttribute("aria-hidden", String(!opened));
      if (opened) {
        sidebar.setAttribute("role", "dialog");
        sidebar.setAttribute("aria-modal", "true");
        sidebar.setAttribute("aria-label", "Workspace navigation");
      } else {
        sidebar.removeAttribute("role");
        sidebar.removeAttribute("aria-modal");
        sidebar.removeAttribute("aria-label");
      }
    } else {
      ["aria-hidden", "role", "aria-modal", "aria-label"].forEach((name) =>
        sidebar.removeAttribute(name),
      );
    }
    if (opened && !wasOpen) focusable()[0]?.focus();
    else if (wasOpen && !opened && restoreFocus && mobile.matches)
      toggle.focus();
  };
  const onBreakpoint = () => {
    const restore = sidebar.contains(document.activeElement);
    setOpen(false, false);
    if (restore)
      (mobile.matches ? toggle : sidebar.querySelector(".nav-link"))?.focus();
  };
  const onKeydown = (event) => {
    if (!opened) return;
    if (event.key === "Escape") {
      event.preventDefault();
      setOpen(false);
      return;
    }
    if (event.key !== "Tab") return;
    const items = focusable(),
      first = items[0],
      last = items[items.length - 1];
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault();
      last?.focus();
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault();
      first?.focus();
    }
  };
  toggle.onclick = () => setOpen(!opened);
  sidebar.querySelector(".sidebar-close").onclick = () => setOpen(false);
  scrim.onclick = () => setOpen(false);
  sidebar.addEventListener("keydown", onKeydown);
  mobile.addEventListener("change", onBreakpoint);
  closeNavigation = () => setOpen(false);
  navigationCleanup = () => {
    mobile.removeEventListener("change", onBreakpoint);
    sidebar.removeEventListener("keydown", onKeydown);
    main.inert = false;
    sidebar.inert = false;
    document.body.style.overflow = "";
    closeNavigation = () => {};
  };
  setOpen(false, false);
}
function renderAuth() {
  navigationCleanup();
  const signup = authMode === "signup",
    authVersion = ++authRenderVersion,
    role = authRole;
  app.innerHTML = `<div class="auth-page"><section class="auth-story">${brand()}<div class="auth-story-main"><div class="eyebrow">Every voice has a beginning</div><h1>Small steps.<br>Stronger words.<br><em>Your voice.</em></h1><p>A thoughtful space for teachers to guide, and learners to discover the confidence to speak.</p><div class="auth-art">${art()}</div></div><div class="auth-story-footer">TEACHER-LED PRACTICE &nbsp; · &nbsp; MEANINGFUL FEEDBACK</div></section><main class="auth-main"><div class="auth-card"><div class="auth-mobile-brand">${brand()}</div><div class="eyebrow">Let's learn together</div><h2>${signup ? "Your teaching space awaits." : "Welcome to Vachak."}</h2><p>${signup ? "Create your teacher account to start a classroom." : "Sign in and take the next step in your learning journey."}</p>${signup ? "" : `<div class="role-toggle" aria-label="Account type"><button data-role="teacher" class="${authRole === "teacher" ? "active" : ""}" aria-pressed="${authRole === "teacher"}">${icon("book", 16)} I'm a teacher</button><button data-role="student" class="${authRole === "student" ? "active" : ""}" aria-pressed="${authRole === "student"}">${icon("users", 16)} I'm a student</button></div>`}<form id="auth-form"><div class="field"><label for="identifier">${signup || authRole === "teacher" ? "Email address" : "Student username"}</label><input id="identifier" name="identifier" type="${signup || authRole === "teacher" ? "email" : "text"}" autocomplete="username" placeholder="${signup || authRole === "teacher" ? "you@school.edu" : "Your teacher-provided username"}" required maxlength="254"></div><div class="field"><label for="password">Password</label><input id="password" name="password" type="password" autocomplete="${signup ? "new-password" : "current-password"}" placeholder="${signup ? "At least 12 characters" : "Enter your password"}" minlength="${signup ? 12 : 1}" maxlength="256" required></div>${signup ? optionalProfileInputs("registration-profile") : ""}<div class="form-error" role="alert"></div><button type="submit" class="button button-primary auth-submit">${signup ? "Create teacher account" : "Sign in to your workspace"} ${icon("arrow", 16)}</button></form><div class="auth-bottom">${signup ? "Already have an account?" : "New here?"} <button class="text-button" data-auth-mode>${signup ? "Sign in" : "Create a teacher account"}</button></div><div class="auth-footnote">${icon("shield", 13)} Student accounts are created by their teacher. Ask your teacher for your username and password.</div></div></main></div>`;
  app.querySelectorAll("[data-role]").forEach(
    (btn) =>
      (btn.onclick = () => {
        authRole = btn.dataset.role;
        renderAuth();
      }),
  );
  app.querySelector("[data-auth-mode]").onclick = () => {
    authMode = signup ? "login" : "signup";
    if (!signup) authRole = "teacher";
    renderAuth();
  };
  app.querySelector("form").onsubmit = async (event) => {
    event.preventDefault();
    const form = event.target,
      data = new FormData(form);
    busy(form, true, signup ? "Creating your account…" : "Signing in…");
    formError(form, "");
    try {
      const result = await api(signup ? "/auth/register" : "/auth/login", {
        method: "POST",
        body: signup
          ? {
              email: data.get("identifier"),
              password: data.get("password"),
              learning_profile: profileValues(form),
            }
          : {
              identifier: data.get("identifier"),
              password: data.get("password"),
              role,
            },
      });
      if (authVersion !== authRenderVersion || !form.isConnected) return;
      saveSession(result);
      if (!result.user) {
        result.user = await api("/auth/me");
        saveSession(result);
      }
      shell();
      go("overview");
    } catch (error) {
      formError(form, error.message);
    } finally {
      busy(form, false);
    }
  };
}

const profileFields = [
  ["country", "Country", "e.g. India", "country-name"],
  ["state_region", "State / region", "e.g. Karnataka", "address-level1"],
  ["city", "City / town", "e.g. Bengaluru", "address-level2"],
  ["first_language", "First language", "e.g. Kannada", "off"],
  [
    "target_accent",
    "Accent you want to practice",
    "e.g. Indian English, British English, or no preference",
    "off",
  ],
];
function profileInputs(profile = {}, prefix = "learning-profile") {
  return `<div class="form-grid profile-fields">${profileFields.map(([key, label, placeholder, autocomplete]) => `<div class="field${key === "target_accent" ? " full" : ""}"><label for="${prefix}-${key}">${label}</label><input id="${prefix}-${key}" name="profile_${key}" value="${E(profile[key] || "")}" maxlength="100" autocomplete="${autocomplete}" placeholder="${placeholder}"></div>`).join("")}</div><p class="micro-copy">All fields are optional. Enter an accent preference yourself; your location does not choose it. No device location is collected.</p>`;
}
function optionalProfileInputs(prefix) {
  return `<details class="collapsible profile-optional"><summary>Language & region <span class="muted">(optional)</span></summary><p class="micro-copy" style="margin-bottom:16px">Add a little context for teaching. You can complete or change this later.</p>${profileInputs({}, prefix)}</details>`;
}
function profileValues(form) {
  const data = new FormData(form);
  return Object.fromEntries(
    profileFields.map(([key]) => [
      key,
      String(data.get(`profile_${key}`) || "").trim(),
    ]),
  );
}
function profileSummary(profile = {}) {
  const filled = profileFields.filter(([key]) => profile[key]);
  return filled.length
    ? `<dl class="detail-list">${filled.map(([key, label]) => `<div><dt>${label}</dt><dd>${E(profile[key])}</dd></div>`).join("")}</dl><p class="micro-copy">${profile.entered_by === "teacher" ? "Entered by the teacher." : profile.entered_by === "self" ? "Self-reported." : "Optional learning context."} Accent preference is not inferred from region.</p>`
    : '<p class="muted small">No language or region details have been added. These are optional, and learning can continue without them.</p>';
}
async function learningProfile(ctx) {
  const role = session().user.role;
  const response = await api(`/${role}/profile`);
  if (!ctx.live()) return;
  const profile = response.learning_profile || {};
  ctx.show(
    heading(
      "A little about your learning.",
      "Share the details you want your learning space to know. Every field is optional.",
      "",
      "Learning profile",
    ) +
      `<div class="two-column"><section class="panel"><h2>Language & region</h2><form id="learning-profile-form">${profileInputs(profile)}<div class="form-error" role="alert"></div><div class="form-actions"><button type="submit" class="button button-primary">Save profile</button></div></form></section><aside><section class="panel"><div class="card-symbol" style="margin-bottom:20px">${icon("leaf", 23)}</div><h2>Your voice belongs here.</h2><p class="muted small">People speak English in many valid ways. Your first language and region provide context; they are not a measure of your ability.</p><div class="notice"><p>An accent preference is something you choose. It is saved as guidance and does not change current scores.</p></div><p class="micro-copy" style="margin-top:18px">${profile.entered_by === "teacher" ? "Your teacher added the current details. You can update them here." : "You control these optional details. Leave a field blank to clear it."}</p></section></aside></div>`,
  );
  const form = ctx.content.querySelector("form");
  form.onsubmit = async (event) => {
    event.preventDefault();
    formError(form, "");
    const body = { learning_profile: profileValues(form) };
    busy(form, true, "Saving…");
    lockEditing(form, true);
    try {
      await api(`/${role}/profile`, { method: "PATCH", body });
      if (ctx.live()) {
        toast("Your learning profile has been saved.");
        route();
      }
    } catch (error) {
      if (ctx.live()) formError(form, error.message);
    } finally {
      busy(form, false);
      lockEditing(form, false);
    }
  };
}
function editStudentProfile(ctx, student) {
  openModal(
    "Learning profile",
    `Optional language and region details for ${student.display_name}.`,
    `<form>${profileInputs(student.learning_profile || {}, "student-profile")}<div class="notice" style="margin-top:20px"><p>These details will be marked as teacher-entered and visible to this student. Accent preference is chosen, not inferred.</p></div><div class="form-error" role="alert"></div><div class="form-actions"><button type="submit" class="button button-primary">Save learning profile</button></div></form>`,
    (el) => {
      const form = el.querySelector("form");
      form.onsubmit = async (event) => {
        event.preventDefault();
        formError(form, "");
        const body = { learning_profile: profileValues(form) };
        busy(form, true, "Saving…");
        lockEditing(form, true);
        try {
          await api(`/teacher/students/${student.id}/profile`, {
            method: "PATCH",
            body,
          });
          if (!ctx.live() || !liveModalForm(form)) return;
          modal.close();
          toast("Student learning profile saved.");
          route();
        } catch (error) {
          if (liveModalForm(form)) formError(form, error.message);
        } finally {
          busy(form, false);
          lockEditing(form, false);
        }
      };
    },
  );
}

async function route() {
  cleanup();
  const version = ++routeVersion;
  if (!session()?.access_token) {
    renderAuth();
    return;
  }
  if (!app.querySelector("#content")) shell();
  closeNavigation();
  const [section = "overview", id, sub] = location.hash
    .replace(/^#\/?/, "")
    .split("/")
    .filter(Boolean);
  if (section === "login") {
    go("overview");
    return;
  }
  const teacher = session().user.role === "teacher";
  const active =
    section === "students"
      ? "progress"
      : section === "practice" || section === "attempts"
        ? "assignments"
        : section;
  app.querySelectorAll("[data-nav]").forEach((link) => {
    const selected = link.dataset.nav === active;
    link.classList.toggle("active", selected);
    selected
      ? link.setAttribute("aria-current", "page")
      : link.removeAttribute("aria-current");
  });
  const names = {
    overview: teacher ? "Overview" : "My learning",
    classrooms: "My classrooms",
    problems: "Problem library",
    assignments: "Assignments",
    progress: "Student progress",
    students: "Student progress",
    practice: "Practice",
    attempts: "Your feedback",
    history: "My progress",
    profile: "Learning profile",
  };
  app.querySelector("#breadcrumb").textContent = names[section] || "Workspace";
  const content = app.querySelector("#content");
  content.innerHTML =
    '<div class="loading"><span class="spinner"></span> Getting your workspace ready…</div>';
  document.title = `${names[section] || "Workspace"} · Vachak AI`;
  window.scrollTo({ top: 0 });
  const ctx = {
    content,
    version,
    live: () => version === routeVersion,
    show: (html) => {
      if (version === routeVersion) content.innerHTML = html;
    },
  };
  try {
    if (teacher) {
      if (section === "overview") await teacherOverview(ctx);
      else if (section === "classrooms")
        id ? await classroomDetail(ctx, id) : await classrooms(ctx);
      else if (section === "problems")
        id === "new"
          ? await createProblem(ctx)
          : id
            ? await problemDetail(ctx, id)
            : await problems(ctx);
      else if (section === "assignments")
        id === "new"
          ? await createAssignment(ctx, sub)
          : id
            ? await teacherAssignment(ctx, id)
            : await teacherAssignments(ctx);
      else if (section === "students" && id) await studentDetail(ctx, id);
      else if (section === "progress") await teacherProgress(ctx);
      else if (section === "profile") await learningProfile(ctx);
      else go("overview");
    } else {
      if (section === "overview") await studentOverview(ctx);
      else if (section === "assignments")
        id ? await studentAssignment(ctx, id) : await studentAssignments(ctx);
      else if (section === "practice" && id && sub)
        await practice(ctx, id, sub);
      else if (section === "attempts" && id) await attemptResult(ctx, id);
      else if (section === "history") await studentHistory(ctx);
      else if (section === "profile") await learningProfile(ctx);
      else go("overview");
    }
    if (ctx.live()) {
      bindReviews(content);
      scope.load(content);
    }
  } catch (error) {
    if (!ctx.live()) return;
    content.innerHTML = `<div class="error-panel"><h3>We couldn't open this page.</h3><p>${E(error.message)}</p><button class="button button-secondary" id="retry-page">Try again</button></div>`;
    content.querySelector("#retry-page").onclick = route;
  }
}

function activity(items, teacher = true) {
  return A(items).length
    ? A(items)
        .slice(0, 6)
        .map(
          (item) =>
            `<div class="activity-item"><span class="activity-icon">${icon(kindIcon(item.kind), 16)}</span><div class="activity-body"><strong>${E(teacher ? item.student_name || "Student practice" : item.problem_title || "Practice")}</strong><p>${E(teacher ? item.problem_title || "Submitted a practice" : item.feedback || "Your practice has been saved.")}</p><div class="activity-meta">${statusBadge(item.status)}<span>${date(item.created_at)}</span></div></div><span class="activity-score">${pct(item.score)}</span></div>`,
        )
        .join("")
    : empty(
        "Your next step starts here",
        teacher
          ? "Student practice and feedback will appear here as your classroom gets started."
          : "Complete your first practice to see your feedback here.",
        "",
        true,
        "leaf",
      );
}
async function teacherOverview(ctx) {
  const [overview, list] = await Promise.all([
    api("/teacher/overview"),
    api("/teacher/classrooms"),
  ]);
  if (!ctx.live()) return;
  const c = overview.counts || {};
  ctx.show(
    heading(
      "Your classroom, ready for today.",
      "A little guidance today can make a big difference tomorrow.",
      linkButton("problems/new", "Create a practice", "primary", "plus"),
      "Your classroom, at a glance",
    ) +
      `<section class="hero"><div class="hero-copy"><div class="eyebrow">Learning begins with a voice</div><h2>Help every student<br>find their confidence.</h2><p>Create a practice in your own voice, share it with your class, and follow their progress, one sentence at a time.</p>${linkButton("problems/new", "Make something to learn", "amber", "arrow")}</div><div class="hero-art">${art()}</div></section><div class="stats-grid">${stat("Your classrooms", c.classrooms, "class")}${stat("Students learning", c.students, "users")}${stat("Practices created", c.problems, "book")}${stat("Awaiting your review", c.needs_review, "message")}</div><div class="two-column"><section class="panel"><div class="panel-heading"><div><h2>My classrooms</h2><p>Small communities, growing together.</p></div><a class="text-button" href="#/classrooms">View all ${icon("arrow", 14)}</a></div>${
        A(list).length
          ? A(list)
              .slice(0, 4)
              .map(
                (cls) =>
                  `<a class="activity-item" href="#/classrooms/${E(cls.id)}"><span class="activity-icon">${icon("class", 18)}</span><div class="activity-body"><strong>${E(cls.name)}</strong><p>${E(cls.school_name)}</p></div><span class="badge">${E(cls.student_count || 0)} students</span></a>`,
              )
              .join("")
          : empty(
              "A classroom of possibilities",
              "Create your first classroom, then invite students into your learning space.",
              linkButton(
                "classrooms",
                "Create a classroom",
                "secondary",
                "plus",
              ),
              true,
              "class",
            )
      }</section><section class="panel"><div class="panel-heading"><div><h2>Recent learning</h2><p>The latest steps your students have taken.</p></div>${icon("leaf", 18)}</div>${activity(overview.recent_activity)}</section></div>`,
  );
  if (A(overview.review_queue).length)
    ctx.content.insertAdjacentHTML(
      "beforeend",
      `<section class="panel review-queue"><div class="panel-heading"><div><h2>Your guidance is needed</h2><p>Listen to a recording or read an answer, then leave a helpful next step.</p></div><span class="badge amber">${overview.review_queue.length} to review</span></div>${overview.review_queue
        .slice(0, 5)
        .map((item) => attemptCard(item, true))
        .join("")}</section>`,
    );
}
async function classrooms(ctx) {
  const list = await api("/teacher/classrooms");
  if (!ctx.live()) return;
  ctx.show(
    heading(
      "My classrooms",
      "Bring your students together by school, class and postal PIN.",
      '<button class="button button-primary" id="new-classroom">' +
        icon("plus", 15) +
        " New classroom</button>",
      "Room to grow",
    ) +
      (A(list).length
        ? `<div class="card-grid">${list.map((cls) => `<a class="class-card" href="#/classrooms/${E(cls.id)}"><div class="card-top"><span class="card-symbol">${icon("class", 23)}</span><span class="badge">${E(cls.student_count || 0)} students</span></div><h3>${E(cls.name)}</h3><p>${E(cls.school_name)}<br>Postal PIN ${E(cls.postal_code)}</p><div class="card-bottom"><span>Open classroom</span>${icon("arrow", 16)}</div></a>`).join("")}</div>`
        : `<section class="panel">${empty("Your first classroom starts here", "Organize your students by school and class. Each classroom has a separate join code for identification.", '<button class="button button-primary" data-new-class>Set up a classroom</button>', false, "class")}</section>`),
  );
  ctx.content
    .querySelectorAll("#new-classroom,[data-new-class]")
    .forEach((btn) => (btn.onclick = createClassroomModal));
}
function createClassroomModal() {
  openModal(
    "Create a classroom",
    "A shared space for your students to practice and grow.",
    `<form><div class="form-grid"><div class="field full"><label for="school-name">School name</label><input id="school-name" name="school_name" placeholder="e.g. Sunrise Public School" required maxlength="200"></div><div class="field"><label for="class-name">Class / section</label><input id="class-name" name="name" placeholder="e.g. Class 6 · Section A" required maxlength="100"></div><div class="field"><label for="postal-code">School postal PIN</label><input id="postal-code" name="postal_code" placeholder="e.g. 560001" required minlength="3" maxlength="12" autocomplete="postal-code"></div></div><div class="form-error" role="alert"></div><div class="form-actions"><button type="submit" class="button button-primary">Create classroom</button></div></form>`,
    (el) => {
      el.querySelector("form").onsubmit = async (event) => {
        event.preventDefault();
        const form = event.target;
        busy(form, true, "Creating…");
        formError(form, "");
        try {
          const result = await api("/teacher/classrooms", {
            method: "POST",
            body: Object.fromEntries(new FormData(form)),
          });
          if (!liveModalForm(form)) return;
          modal.close();
          toast("Your classroom is ready. Add your first student.");
          go(`classrooms/${result.id}`);
        } catch (error) {
          formError(form, error.message);
        } finally {
          busy(form, false);
        }
      };
    },
  );
}
async function classroomDetail(ctx, id) {
  const cls = await api(`/teacher/classrooms/${id}`);
  if (!ctx.live()) return;
  ctx.show(
    `<a class="back-link" href="#/classrooms">${icon("back", 14)} All classrooms</a>` +
      heading(
        cls.name,
        `${cls.school_name} · Postal PIN ${cls.postal_code}`,
        '<button class="button button-primary" id="add-student">' +
          icon("plus", 15) +
          " Add student</button>",
        "A place to learn together",
      ) +
      `<div class="stats-grid">${stat("Enrolled students", A(cls.students).length, "users")}${stat("Classroom code", cls.join_code || "—", "class", "Separate from the school postal PIN")}</div><section class="panel"><div class="panel-heading"><div><h2>Your students</h2><p>Open a learner's profile to see practice, progress and feedback.</p></div>${linkButton("assignments/new", "Assign practice", "secondary", "clipboard")}</div>${A(cls.students).length ? `<div class="table-wrap"><table><thead><tr><th>Student</th><th>Username</th><th></th></tr></thead><tbody>${cls.students.map((student) => `<tr><td><a class="student-cell" href="#/students/${E(student.id)}"><span class="avatar">${E(initials(student.display_name))}</span><strong>${E(student.display_name)}</strong></a></td><td class="muted">${E(student.login_name)}</td><td><a class="text-button" href="#/students/${E(student.id)}">View progress ${icon("arrow", 14)}</a></td></tr>`).join("")}</tbody></table></div>` : empty("A warm welcome starts with you", "Add a student to create their login. Share their username and initial password with them.", '<button class="button button-secondary" data-add-student>Add your first student</button>', false, "users")}</section>`,
  );
  ctx.content.querySelectorAll("#add-student,[data-add-student]").forEach(
    (btn) =>
      (btn.onclick = () =>
        openModal(
          "Welcome a new learner",
          "Create their account and share the sign-in details with them.",
          `<form><div class="form-grid"><div class="field full"><label for="student-name">Student's full name</label><input id="student-name" name="display_name" required maxlength="100" autocomplete="off" placeholder="e.g. Aarav Sharma"></div><div class="field full"><label for="student-login">Unique student username</label><input id="student-login" name="login_name" required minlength="3" maxlength="80" autocomplete="off" placeholder="e.g. aarav.class6"><small>Use letters, numbers, dots, underscores or hyphens.</small></div><div class="field full"><label for="student-password">Initial password</label><input id="student-password" name="password" type="password" required minlength="8" maxlength="256" autocomplete="new-password" placeholder="At least 8 characters"><small>Share this securely. The password cannot be retrieved later.</small></div></div>${optionalProfileInputs("new-student-profile")}<div class="form-error" role="alert"></div><div class="form-actions"><button type="submit" class="button button-primary">Add student</button></div></form>`,
          (el) => {
            el.querySelector("form").onsubmit = async (event) => {
              event.preventDefault();
              const form = event.target;
              busy(form, true, "Adding student…");
              formError(form, "");
              try {
                await api(`/teacher/classrooms/${id}/students`, {
                  method: "POST",
                  body: {
                    display_name: form.querySelector("[name=display_name]")
                      .value,
                    login_name: form.querySelector("[name=login_name]").value,
                    password: form.querySelector("[name=password]").value,
                    learning_profile: profileValues(form),
                  },
                });
                if (!ctx.live() || !liveModalForm(form)) return;
                modal.close();
                toast("Student added. Their sign-in is ready to use.");
                route();
              } catch (error) {
                formError(form, error.message);
              } finally {
                busy(form, false);
              }
            };
          },
        )),
  );
}

function problemCard(problem) {
  return `<a class="problem-card" href="#/problems/${E(problem.id)}"><div class="card-top"><span class="card-symbol">${icon(kindIcon(problem.kind), 22)}</span>${badge(problem.kind)}</div><h3>${E(problem.title)}</h3><p>${E((problem.expected_text || "").slice(0, 130))}${problem.expected_text?.length > 130 ? "…" : ""}</p><div class="card-bottom"><span class="id-label">${shortId(problem.id)}</span><span>Open practice ${icon("arrow", 12)}</span></div></a>`;
}
async function problems(ctx) {
  const list = A(await api("/teacher/problems"));
  if (!ctx.live()) return;
  ctx.show(
    heading(
      "Your problem library",
      "A collection of little challenges, made by you. Create once, assign whenever.",
      linkButton("problems/new", "Create a practice", "primary", "plus"),
      "Made for their next step",
    ) +
      `<div class="filters"><div class="tabs" aria-label="Practice type"><button class="tab active" data-kind="all">All practices</button>${["read_aloud", "choice", "matching", "meaning"].map((kind) => `<button class="tab" data-kind="${kind}">${kindName(kind)}</button>`).join("")}</div><div class="search-field">${icon("search", 16)}<input type="search" id="problem-search" aria-label="Search practices" placeholder="Search title or problem ID"></div></div><div id="problem-results"></div>`,
  );
  let filter = "all";
  const results = ctx.content.querySelector("#problem-results"),
    search = ctx.content.querySelector("#problem-search");
  const render = () => {
    const query = search.value.trim().toLowerCase();
    const found = list.filter(
      (p) =>
        (filter === "all" || p.kind === filter) &&
        `${p.title} ${p.id}`.toLowerCase().includes(query),
    );
    results.innerHTML = found.length
      ? `<div class="card-grid">${found.map(problemCard).join("")}</div>`
      : `<section class="panel">${empty(list.length ? "No practices found" : "Start with a single sentence", list.length ? "Try a different search or choose another practice type." : "Record your voice, build a word quiz, match ideas or explore meaning.", list.length ? "" : linkButton("problems/new", "Create your first practice", "primary", "plus"))}</section>`;
  };
  ctx.content.querySelectorAll("[data-kind]").forEach(
    (btn) =>
      (btn.onclick = () => {
        filter = btn.dataset.kind;
        ctx.content
          .querySelectorAll("[data-kind]")
          .forEach((other) => other.classList.toggle("active", other === btn));
        render();
      }),
  );
  search.oninput = render;
  render();
}

async function createProblem(ctx) {
  ctx.show(
    `<a class="back-link" href="#/problems">${icon("back", 14)} Your problem library</a>` +
      heading(
        "Make something to learn.",
        "A new practice, a small challenge, a chance to grow. Start with the format.",
        "",
        "Create a practice",
      ) +
      `<div class="two-column"><section class="panel"><div class="type-grid">${["read_aloud", "choice", "matching", "meaning"].map((kind) => `<button type="button" class="type-option ${kind === "read_aloud" ? "active" : ""}" data-create-kind="${kind}">${icon(kindIcon(kind), 23)}${kindName(kind)}</button>`).join("")}</div><form id="problem-form"><div class="form-grid"><div class="field full"><label for="problem-title">Practice title</label><input id="problem-title" name="title" required maxlength="200" placeholder="Give this practice a memorable name"></div></div><div id="kind-fields" style="margin-top:20px"></div><div class="field" style="margin-top:20px"><label for="teaching-notes">A note for your students <span class="muted">(optional)</span></label><textarea id="teaching-notes" name="teaching_notes" maxlength="5000" placeholder="Offer a helpful hint, explain a tricky word, or encourage them to take their time."></textarea></div><div class="form-error" role="alert"></div><div class="form-actions"><a class="button button-secondary" href="#/problems">Cancel</a><button type="submit" class="button button-primary">Save practice</button></div></form></section><aside><section class="panel"><div class="card-symbol" style="margin-bottom:20px">${icon("leaf", 23)}</div><h2>Your guidance matters.</h2><p class="muted small">Keep each practice focused on one small learning goal. A clear example and a helpful note can make all the difference.</p><div class="notice amber" style="margin-top:22px">${icon("mic", 16)}<p>Voice recordings keep their original audio. Experimental pitch and pause evidence can support listening feedback; pitch is never part of the score.</p></div></section><section class="panel"><h3>From your library to their learning</h3><p class="muted small">Every saved practice gets its own ID. Assign it to an entire classroom or give one student a little extra attention.</p></section></aside></div>`,
  );
  const form = ctx.content.querySelector("#problem-form"),
    fields = ctx.content.querySelector("#kind-fields");
  let kind = "read_aloud",
    recorder = null,
    rowCount = 0,
    createdId = null;
  function renderFields() {
    recorder?.dispose();
    recorder = null;
    createdId = null;
    rowCount = 0;
    const promptLabel =
      kind === "read_aloud"
        ? "Sentence to read aloud"
        : kind === "meaning"
          ? "Sentence or phrase to explain"
          : "Question / instructions";
    fields.innerHTML = `<div class="field"><label for="expected-text">${promptLabel}</label><textarea id="expected-text" name="expected_text" required maxlength="5000" placeholder="${kind === "read_aloud" ? "e.g. This is my house. I feel happy to be home." : kind === "meaning" ? "e.g. A friend in need is a friend indeed." : "e.g. Choose the word with a similar meaning to “happy”."}"></textarea></div>`;
    if (kind === "read_aloud") {
      fields.insertAdjacentHTML(
        "beforeend",
        '<div class="field" style="margin-top:18px"><label for="expression">Reading expression <span class="muted">(optional)</span></label><input id="expression" name="expression" maxlength="200" placeholder="e.g. Warm and welcoming, with a pause after “house”"><small>Guidance for your students, preserved for future expression analysis.</small></div><div class="field" style="margin-top:22px"><label>Your reference recording</label><div class="recorder" id="teacher-recorder"></div></div>',
      );
      recorder = mountRecorder(
        fields.querySelector("#teacher-recorder"),
        scope,
      );
    } else if (kind === "choice" || kind === "matching") {
      fields.insertAdjacentHTML(
        "beforeend",
        `<div class="field" style="margin-top:18px"><label for="word-skill">Language skill</label><select id="word-skill" name="skill"><option value="synonym">Synonyms</option><option value="antonym">Antonyms</option><option value="vocabulary">Vocabulary</option></select></div><div class="section-heading"><h3>${kind === "choice" ? "Answer choices" : "Matching pairs"}</h3><button class="text-button" type="button" id="add-answer">${icon("plus", 14)} Add ${kind === "choice" ? "choice" : "pair"}</button></div><p class="micro-copy" style="margin-bottom:15px">${kind === "choice" ? "Select the circle beside the correct answer." : "Enter the matching items beside each other. Students receive shuffled cards."}</p><div id="answer-rows"></div>`,
      );
      fields.querySelector("#add-answer").onclick = () => addRow();
      for (let i = 0; i < (kind === "choice" ? 3 : 3); i++) addRow();
    } else {
      fields.insertAdjacentHTML(
        "beforeend",
        '<div class="field" style="margin-top:18px"><label for="accepted-answers">Example correct meanings</label><textarea id="accepted-answers" name="accepted_answers" required maxlength="5000" placeholder="One example per line. Related meanings can also be accepted."></textarea><small>Only teachers can see these examples.</small></div><div class="field" style="margin-top:18px"><label for="meaning-rubric">What should a good answer convey?</label><textarea id="meaning-rubric" name="rubric" required maxlength="5000" placeholder="Describe the important idea, and which partial meanings deserve credit."></textarea><small>Used for evaluation and teacher review; hidden from students.</small></div>',
      );
    }
  }
  function addRow() {
    const container = fields.querySelector("#answer-rows");
    if (container.children.length >= 10) {
      toast("Keep this practice to 10 options or pairs.");
      return;
    }
    const id = `row-${++rowCount}`;
    container.insertAdjacentHTML(
      "beforeend",
      kind === "choice"
        ? `<div class="row-inputs" data-row="${id}"><input class="correct-radio" type="radio" name="correct" value="${id}" aria-label="Mark option ${rowCount} correct" required><div class="field"><input data-option required maxlength="500" placeholder="Answer option" aria-label="Answer option ${rowCount}"></div><button type="button" class="icon-button" data-remove-row aria-label="Remove option">${icon("close", 15)}</button></div>`
        : `<div class="row-inputs" data-row="${id}"><div class="field"><input data-left required maxlength="500" placeholder="First word / idea" aria-label="Left side of pair ${rowCount}"></div><span class="matching-arrow">${icon("arrow", 16)}</span><div class="field"><input data-right required maxlength="500" placeholder="Its matching pair" aria-label="Right side of pair ${rowCount}"></div><button type="button" class="icon-button" data-remove-row aria-label="Remove pair">${icon("close", 15)}</button></div>`,
    );
    container.lastElementChild.querySelector("[data-remove-row]").onclick = (
      event,
    ) => {
      if (container.children.length <= 2) {
        toast("Keep at least two options or pairs.");
        return;
      }
      event.currentTarget.closest("[data-row]").remove();
    };
  }
  ctx.content.querySelectorAll("[data-create-kind]").forEach(
    (btn) =>
      (btn.onclick = () => {
        if (createdId) {
          toast("Finish saving this practice or return to your library first.");
          return;
        }
        kind = btn.dataset.createKind;
        ctx.content
          .querySelectorAll("[data-create-kind]")
          .forEach((other) => other.classList.toggle("active", other === btn));
        renderFields();
      }),
  );
  renderFields();
  form.onsubmit = async (event) => {
    event.preventDefault();
    formError(form, "");
    if (recorder?.isRecording) {
      formError(form, "Stop the recording before saving your practice.");
      return;
    }
    const data = new FormData(form);
    let payload = {};
    if (kind === "read_aloud")
      payload = { expression: data.get("expression") || "" };
    if (kind === "choice") {
      const rows = [...fields.querySelectorAll("[data-row]")];
      payload = {
        skill: data.get("skill"),
        options: rows.map((row) => ({
          id: row.dataset.row,
          text: row.querySelector("[data-option]").value.trim(),
        })),
        correct_option_id: data.get("correct"),
      };
      if (!payload.correct_option_id) {
        formError(form, "Choose the correct answer for this quiz.");
        return;
      }
    }
    if (kind === "matching")
      payload = {
        skill: data.get("skill"),
        pairs: [...fields.querySelectorAll("[data-row]")].map((row) => ({
          id: row.dataset.row,
          left: row.querySelector("[data-left]").value.trim(),
          right: row.querySelector("[data-right]").value.trim(),
        })),
      };
    if (kind === "meaning")
      payload = {
        accepted_answers: String(data.get("accepted_answers"))
          .split("\n")
          .map((s) => s.trim())
          .filter(Boolean),
        rubric: data.get("rubric"),
      };
    const submittedKind = kind,
      submittedFile = recorder?.file || null;
    busy(form, true, "Saving your practice…");
    lockEditing(form, true);
    ctx.content
      .querySelectorAll("[data-create-kind]")
      .forEach((button) => (button.disabled = true));
    try {
      if (!createdId) {
        const result = await api("/teacher/problems", {
          method: "POST",
          body: {
            title: data.get("title"),
            kind: submittedKind,
            expected_text: data.get("expected_text"),
            teaching_notes: data.get("teaching_notes"),
            payload,
          },
        });
        createdId = result.id;
      }
      if (!ctx.live()) return;
      if (submittedKind === "read_aloud" && submittedFile) {
        const audio = new FormData();
        audio.append("file", submittedFile);
        await api(`/problems/${createdId}/recordings`, {
          method: "POST",
          body: audio,
        });
      }
      if (!ctx.live()) return;
      toast(
        submittedKind === "read_aloud" && !submittedFile
          ? "Practice saved. Add a reference recording before assigning it."
          : "Your practice is ready in the library.",
      );
      go(`problems/${createdId}`);
    } catch (error) {
      if (ctx.live())
        formError(
          form,
          createdId
            ? `The practice was saved, but its audio needs attention: ${error.message} Retry to upload without creating a duplicate. Saved question details are now fixed.`
            : error.message,
        );
    } finally {
      busy(form, false);
      lockEditing(form, false);
      if (ctx.live()) {
        ctx.content
          .querySelectorAll("[data-create-kind]")
          .forEach((button) => (button.disabled = !!createdId));
        if (createdId)
          form
            .querySelectorAll(
              "input:not([type=file]),textarea,select,#add-answer,[data-remove-row]",
            )
            .forEach((control) => (control.disabled = true));
      }
    }
  };
}

async function problemDetail(ctx, id) {
  const problem = await api(`/teacher/problems/${id}`);
  const recordings =
    problem.recordings ||
    (problem.kind === "read_aloud"
      ? await api(`/problems/${id}/recordings`)
      : []);
  if (!ctx.live()) return;
  const payload = problem.payload || {};
  let details = "";
  if (problem.kind === "choice")
    details = `<div class="question-options">${A(payload.options)
      .map(
        (option, i) =>
          `<div class="choice-option"><span class="option-letter">${String.fromCharCode(65 + i)}</span><span style="flex:1">${E(option.text)}</span>${option.id === payload.correct_option_id ? '<span class="badge green">Correct answer</span>' : ""}</div>`,
      )
      .join("")}</div>`;
  if (problem.kind === "matching")
    details = `<div class="table-wrap"><table><thead><tr><th>First item</th><th>Matching item</th></tr></thead><tbody>${A(
      payload.pairs,
    )
      .map(
        (pair) => `<tr><td>${E(pair.left)}</td><td>${E(pair.right)}</td></tr>`,
      )
      .join("")}</tbody></table></div>`;
  if (problem.kind === "meaning")
    details = `<h3>Example meanings</h3><div class="notes">${A(payload.accepted_answers).map(E).join("\n")}</div><h3 style="margin-top:24px">Teacher's evaluation guide</h3><div class="notes">${E(payload.rubric)}</div>`;
  ctx.show(
    `<a class="back-link" href="#/problems">${icon("back", 14)} Your problem library</a>` +
      heading(
        problem.title,
        `Problem ID · ${problem.id}`,
        linkButton(
          `assignments/new/${id}`,
          "Assign this practice",
          "primary",
          "clipboard",
        ),
      ) +
      `<div class="two-column"><section class="panel"><div class="panel-heading">${badge(problem.kind)}<span class="micro-copy">Created ${date(problem.created_at)}</span></div><div class="quote">${E(problem.expected_text)}</div>${details}${payload.expression ? `<div class="notice amber">${icon("sound", 16)}<p><strong>Expression guidance:</strong> ${E(payload.expression)}</p></div>` : ""}${problem.teaching_notes ? `<h3 style="margin-top:25px">A note for students</h3><div class="notes">${E(problem.teaching_notes)}</div>` : ""}</section><aside>${problem.kind === "read_aloud" ? `<section class="panel"><div class="panel-heading"><h2>Reference recordings</h2><span class="badge">${recordings.length}</span></div>${recordings.length ? recordings.map((recording, i) => `<div class="recording-row"><div class="recording-meta"><span>Recording ${i + 1} · ${Number(recording.duration_seconds || 0).toFixed(1)}s</span><span>${date(recording.created_at)}</span></div>${audioPlayer(recording.playback_url || `/recordings/${recording.id}/audio`, "Teacher reference recording")}<div class="micro-copy">Original recording preserved · ${shortId(recording.id)}</div>${recording.measurements?.pitch ? `<details class="collapsible"><summary>View reference pitch contour</summary>${pitchEvidence(recording.measurements.pitch)}</details>` : ""}</div>`).join("") : empty("Your voice goes here", "Record a clear example before assigning this reading practice.", "", true, "mic")}</section><section class="panel"><h3>Add a reference recording</h3><form id="upload-reference"><div id="reference-recorder" class="recorder"></div><div class="form-error" role="alert"></div><div class="form-actions"><button type="submit" class="button button-primary">Save recording</button></div></form></section>` : `<section class="panel"><div class="card-symbol" style="margin-bottom:20px">${icon("shield", 23)}</div><h3>Ready to share</h3><p class="muted small">Students see the question and your teaching notes. Answer keys and evaluation guides stay in your teacher workspace.</p>${linkButton(`assignments/new/${id}`, "Create an assignment", "secondary", "arrow")}</section>`}</aside></div>`,
  );
  if (problem.kind === "read_aloud") {
    const form = ctx.content.querySelector("#upload-reference"),
      recorder = mountRecorder(
        ctx.content.querySelector("#reference-recorder"),
        scope,
      );
    form.onsubmit = async (event) => {
      event.preventDefault();
      formError(form, "");
      if (recorder.isRecording) {
        formError(form, "Stop your recording before uploading.");
        return;
      }
      if (!recorder.file) {
        formError(form, "Record your voice or select an audio file first.");
        return;
      }
      busy(form, true, "Saving recording…");
      try {
        const body = new FormData();
        body.append("file", recorder.file);
        await api(`/problems/${id}/recordings`, { method: "POST", body });
        if (!ctx.live()) return;
        toast("Reference recording saved.");
        route();
      } catch (error) {
        formError(form, error.message);
      } finally {
        busy(form, false);
      }
    };
  }
}

function assignmentCard(item, student = false) {
  const completed = Number(item.completed_count || 0),
    total = Number(item.problem_count || 0),
    ratio = total ? Math.min(100, (completed / total) * 100) : 0;
  return `<a class="assignment-card" href="#/assignments/${E(item.id)}"><div class="card-top"><span class="card-symbol">${icon("clipboard", 22)}</span>${student ? `<span class="badge ${completed === total && total ? "green" : "amber"}">${completed === total && total ? "Completed" : completed ? "In progress" : "Ready to start"}</span>` : `<span class="badge">${E(item.student_count || 0)} students</span>`}</div><h3>${E(item.title)}</h3><p>${E(student ? item.teacher_name || "Assigned by your teacher" : item.target_label || "Your classroom")}</p>${student ? `<div class="progress-caption"><span>${completed} of ${total} completed</span><span>${Math.round(ratio)}%</span></div><div class="progress-track"><div class="progress-fill" style="width:${ratio}%"></div></div>` : ""}<div class="card-bottom"><span>${total} ${total === 1 ? "practice" : "practices"} · ${date(item.created_at)}</span>${icon("arrow", 16)}</div></a>`;
}
async function teacherAssignments(ctx) {
  const list = A(await api("/teacher/assignments"));
  if (!ctx.live()) return;
  ctx.show(
    heading(
      "Assignments, made personal.",
      "Share a practice with your classroom or focus on an individual learner.",
      linkButton("assignments/new", "New assignment", "primary", "plus"),
      "A little direction goes a long way",
    ) +
      (list.length
        ? `<div class="card-grid">${list.map((item) => assignmentCard(item)).join("")}</div>`
        : `<section class="panel">${empty("A practice is better when shared", "Choose one or more practices from your library and send them to your students.", linkButton("assignments/new", "Create an assignment", "primary", "plus"), false, "clipboard")}</section>`),
  );
}
async function createAssignment(ctx, defaultProblemId = null) {
  const [classList, problemList] = await Promise.all([
    api("/teacher/classrooms"),
    api("/teacher/problems"),
  ]);
  if (!ctx.live()) return;
  if (!A(classList).length || !A(problemList).length) {
    ctx.show(
      heading(
        "Create an assignment",
        "Bring a classroom and a practice together.",
      ) +
        `<section class="panel">${empty(!A(classList).length ? "Create a classroom first" : "Add a practice to your library", !A(classList).length ? "A classroom helps you choose the students who will receive this assignment." : "Create a reading, word, matching or meaning practice before sharing it with students.", linkButton(!A(classList).length ? "classrooms" : "problems/new", !A(classList).length ? "My classrooms" : "Create a practice", "primary", "plus"), false, "clipboard")}</section>`,
    );
    return;
  }
  ctx.show(
    `<a class="back-link" href="#/assignments">${icon("back", 14)} All assignments</a>` +
      heading(
        "A new step for your learners.",
        "Choose who it is for, then fill it with meaningful practice.",
        "",
        "Create an assignment",
      ) +
      `<form id="assignment-form"><div class="two-column"><section class="panel"><h2>Who are we helping today?</h2><div class="form-grid"><div class="field full"><label for="assignment-title">Assignment title</label><input id="assignment-title" name="title" required maxlength="200" placeholder="e.g. Our words for the week"></div><div class="field full"><label for="assignment-target">Assign to</label><select id="assignment-target" name="target"><option value="class">An entire classroom</option><option value="student">An individual student</option></select></div><div class="field full"><label for="assignment-class">Classroom</label><select id="assignment-class" required><option value="">Choose a classroom</option>${classList.map((cls) => `<option value="${E(cls.id)}">${E(cls.name)} · ${E(cls.school_name)}</option>`).join("")}</select></div><div class="field full" id="student-target-field" hidden><label for="assignment-student">Student</label><select id="assignment-student"><option value="">Choose a classroom first</option></select></div></div><div class="notice" style="margin-top:23px">${icon("users", 16)}<p id="recipient-note">Choose a classroom to see who will receive this assignment.</p></div></section><section class="panel"><div class="panel-heading"><div><h2>Choose their practices</h2><p>Reusable problems, selected from your library.</p></div><span class="badge" id="selected-count">0 selected</span></div><div class="search-field" style="max-width:none;margin-bottom:15px">${icon("search", 16)}<input id="assignment-search" type="search" aria-label="Search available practices" placeholder="Search a title or problem ID"></div><div id="assignment-problems">${problemList.map((problem) => `<div class="assignment-problem" data-problem-row="${E(problem.id)}"><label class="check-row"><input type="checkbox" value="${E(problem.id)}" data-select-problem><span class="check-copy"><strong>${E(problem.title)}</strong><small>${kindName(problem.kind)} · ${shortId(problem.id)}</small></span></label><div class="reference-select" data-reference-for="${E(problem.id)}" hidden></div></div>`).join("")}</div><div class="micro-copy" style="margin-top:18px">Need something new? <a class="inline-link" href="#/problems/new">Create a practice in your library.</a></div></section></div><div class="form-error" role="alert"></div><div class="form-actions"><a class="button button-secondary" href="#/assignments">Cancel</a><button type="submit" class="button button-primary">Send assignment ${icon("arrow", 15)}</button></div><p class="micro-copy" style="text-align:right">This creates a saved copy of the practices for the currently selected students.</p></form>`,
  );
  const form = ctx.content.querySelector("form"),
    target = form.querySelector("#assignment-target"),
    classSelect = form.querySelector("#assignment-class"),
    studentSelect = form.querySelector("#assignment-student"),
    note = form.querySelector("#recipient-note"),
    selected = new Map();
  let members = [],
    classVersion = 0,
    assignmentRequestId = makeRequestId(),
    lastAssignmentFingerprint = null;
  const updateTarget = () => {
    const individual = target.value === "student";
    form.querySelector("#student-target-field").hidden = !individual;
    studentSelect.required = individual;
    note.textContent = classSelect.value
      ? individual
        ? "Only the selected student receives this assignment."
        : `${members.length} enrolled ${members.length === 1 ? "student will" : "students will"} receive this assignment.`
      : "Choose a classroom to see who will receive this assignment.";
  };
  classSelect.onchange = async () => {
    const version = ++classVersion;
    members = [];
    studentSelect.innerHTML = '<option value="">Loading students…</option>';
    studentSelect.disabled = true;
    updateTarget();
    if (!classSelect.value) {
      studentSelect.innerHTML =
        '<option value="">Choose a classroom first</option>';
      studentSelect.disabled = false;
      return;
    }
    try {
      const cls = await api(`/teacher/classrooms/${classSelect.value}`);
      if (version !== classVersion || !ctx.live()) return;
      members = A(cls.students);
      studentSelect.innerHTML = members.length
        ? '<option value="">Choose a student</option>' +
          members
            .map(
              (student) =>
                `<option value="${E(student.id)}">${E(student.display_name)} · ${E(student.login_name)}</option>`,
            )
            .join("")
        : '<option value="">No students in this classroom</option>';
      updateTarget();
    } catch (error) {
      formError(form, error.message);
      studentSelect.innerHTML =
        '<option value="">Students unavailable</option>';
    } finally {
      studentSelect.disabled = false;
    }
  };
  target.onchange = updateTarget;
  form.querySelector("#assignment-search").oninput = (event) => {
    const query = event.target.value.trim().toLowerCase();
    form.querySelectorAll("[data-problem-row]").forEach((row) => {
      const p = problemList.find((item) => item.id === row.dataset.problemRow);
      row.hidden = !`${p.title} ${p.id}`.toLowerCase().includes(query);
    });
  };
  form.querySelectorAll("[data-select-problem]").forEach(
    (check) =>
      (check.onchange = async () => {
        const problem = problemList.find((p) => p.id === check.value),
          row = check.closest("[data-problem-row]"),
          ref = row.querySelector("[data-reference-for]");
        if (!check.checked) {
          selected.delete(problem.id);
          ref.hidden = true;
        } else {
          selected.set(problem.id, { problem_id: problem.id });
          if (problem.kind === "read_aloud") {
            ref.hidden = false;
            ref.innerHTML =
              '<div class="audio-loading">Loading reference recordings…</div>';
            try {
              const detail = await api(`/teacher/problems/${problem.id}`);
              const recordings =
                detail.recordings ||
                (await api(`/problems/${problem.id}/recordings`));
              if (!ctx.live() || !check.checked) return;
              if (!recordings.length) {
                ref.innerHTML = `<p class="field-error">Add a reference recording before assigning this reading practice. <a class="inline-link" href="#/problems/${E(problem.id)}">Open practice</a></p>`;
              } else {
                ref.innerHTML = `<div class="field"><label for="ref-${E(problem.id)}">Teacher's reference</label><select id="ref-${E(problem.id)}">${recordings.map((rec, i) => `<option value="${E(rec.id)}">Recording ${i + 1} · ${Number(rec.duration_seconds || 0).toFixed(1)}s · ${date(rec.created_at)}</option>`).join("")}</select></div>`;
                const select = ref.querySelector("select");
                selected.get(problem.id).recording_id = select.value;
                select.onchange = () => {
                  if (selected.has(problem.id))
                    selected.get(problem.id).recording_id = select.value;
                };
              }
            } catch (error) {
              ref.innerHTML = `<p class="field-error">${E(error.message)} Deselect and select this practice to retry.</p>`;
            }
          }
        }
        form.querySelector("#selected-count").textContent =
          `${selected.size} selected`;
      }),
  );
  if (defaultProblemId) {
    const checkbox = [...form.querySelectorAll("[data-select-problem]")].find(
      (item) => item.value === defaultProblemId,
    );
    if (checkbox) {
      checkbox.checked = true;
      checkbox.dispatchEvent(new Event("change"));
    }
  }
  form.onsubmit = async (event) => {
    event.preventDefault();
    formError(form, "");
    if (!selected.size) {
      formError(form, "Choose at least one practice for this assignment.");
      return;
    }
    if (!members.length) {
      formError(
        form,
        "Add students to this classroom before assigning practices.",
      );
      return;
    }
    if (
      [...selected.values()].some(
        (item) =>
          problemList.find((p) => p.id === item.problem_id)?.kind ===
            "read_aloud" && !item.recording_id,
      )
    ) {
      formError(
        form,
        "Each selected reading practice needs a reference recording.",
      );
      return;
    }
    busy(form, true, "Sending assignment…");
    try {
      const body = {
        title: form.querySelector("[name=title]").value,
        problems: [...selected.values()],
        ...(target.value === "student"
          ? { student_id: studentSelect.value }
          : { classroom_id: classSelect.value }),
      };
      const fingerprint = JSON.stringify(body);
      if (
        lastAssignmentFingerprint !== null &&
        fingerprint !== lastAssignmentFingerprint
      )
        assignmentRequestId = makeRequestId();
      lastAssignmentFingerprint = fingerprint;
      body.request_id = assignmentRequestId;
      lockEditing(form, true);
      const result = await api("/teacher/assignments", {
        method: "POST",
        body,
      });
      if (!ctx.live()) return;
      toast("Assignment sent. Your students can start practicing.");
      go(`assignments/${result.id}`);
    } catch (error) {
      formError(form, error.message);
    } finally {
      busy(form, false);
      lockEditing(form, false);
    }
  };
}

function attemptCard(attempt, review = false) {
  const display = attempt.answer_display ?? attempt.answer;
  const textAnswer = typeof display === "string" ? display : null;
  const pairAnswer = Array.isArray(display) ? display : null;
  return `<article class="attempt-card"><div class="attempt-heading"><div><h3>${E(attempt.problem_title || "Practice attempt")}${review && attempt.student_name ? ` <span class="muted">· ${E(attempt.student_name)}</span>` : ""}</h3><p>${kindName(attempt.kind)} · ${date(attempt.created_at)} · Attempt ${shortId(attempt.id)}</p></div><div class="button-row">${statusBadge(attempt.status)}<span class="activity-score">${pct(attempt.score)}</span></div></div>${textAnswer ? `<div class="attempt-answer"><strong>Submitted answer:</strong> ${E(textAnswer)}</div>` : ""}${pairAnswer ? `<div class="table-wrap"><table><thead><tr><th>Item</th><th>Student's match</th></tr></thead><tbody>${pairAnswer.map((pair) => `<tr><td>${E(pair.left)}</td><td>${E(pair.right)}</td></tr>`).join("")}</tbody></table></div>` : ""}${attempt.reference_audio_url ? `<p class="micro-copy" style="margin-bottom:8px">Teacher's reference</p>${audioPlayer(attempt.reference_audio_url, "Teacher reference recording")}` : ""}${attempt.audio_url ? `<p class="micro-copy" style="margin-bottom:8px">Student's recording</p>${audioPlayer(attempt.audio_url, "Student practice recording")}` : ""}${attempt.result?.teacher_review ? `<div class="teacher-guidance"><span class="eyebrow">Teacher feedback</span><p>${E(attempt.feedback || attempt.result.teacher_review.feedback)}</p></div>` : attempt.feedback || attempt.display_feedback?.summary ? `<p class="attempt-feedback">${E(attempt.display_feedback?.summary || attempt.feedback)}</p>` : ""}${review && typeof attempt.result?.suggested_score === "number" && !attempt.result?.teacher_review ? `<div class="notice amber" style="margin-top:14px">${icon("message", 16)}<p><strong>Unverified AI suggestion: ${pct(attempt.result.suggested_score)}</strong><br>${E(attempt.result.explanation || "Use your own judgment before choosing a score. This suggestion is hidden from students.")}</p></div>` : ""}${review && attempt.kind === "read_aloud" && attempt.status !== "pending" ? `<details class="collapsible reading-guidance" open><summary>Reading guidance</summary>${simpleReadingFeedback(attempt)}<details class="collapsible technical-evidence"><summary>Detailed analysis <span class="muted">(optional)</span></summary>${readingMetrics(attempt.result, attempt.status)}</details></details>` : ""}${review ? `<div class="attempt-actions"><button class="text-button" data-review="${E(attempt.id)}" data-score="${attempt.score ?? ""}" data-feedback="${E(attempt.feedback || "")}">${icon("message", 14)} ${attempt.status === "needs_review" ? "Give feedback" : "Review attempt"}</button></div>` : `<div class="attempt-actions"><a class="text-button" href="#/attempts/${E(attempt.id)}">Open feedback ${icon("arrow", 14)}</a></div>`}</article>`;
}
function bindReviews(container) {
  container.querySelectorAll("[data-review]").forEach(
    (button) =>
      (button.onclick = () =>
        openModal(
          "A little feedback goes a long way",
          "Listen, consider the answer, and leave your guidance for this learner.",
          `<form><div class="form-grid"><div class="field full"><label for="review-score">Your score (0–100%)</label><input type="number" id="review-score" name="score" min="0" max="100" step="1" required value="${button.dataset.score !== "" ? Math.round(Number(button.dataset.score) * 100) : ""}" placeholder="e.g. 75"><small>A teacher review replaces the displayed score and marks this attempt complete.</small></div><div class="field full"><label for="review-feedback">Helpful feedback</label><textarea id="review-feedback" name="feedback" required maxlength="5000" placeholder="What went well, and what should the student try next?">${E(button.dataset.feedback)}</textarea></div></div><div class="form-error" role="alert"></div><div class="form-actions"><button class="button button-primary" type="submit">Save teacher feedback</button></div></form>`,
          (el) => {
            el.querySelector("form").onsubmit = async (event) => {
              event.preventDefault();
              const form = event.target;
              busy(form, true, "Saving feedback…");
              formError(form, "");
              try {
                await api(`/teacher/attempts/${button.dataset.review}/review`, {
                  method: "PATCH",
                  body: {
                    score:
                      Number(form.querySelector("[name=score]").value) / 100,
                    feedback: form.querySelector("[name=feedback]").value,
                  },
                });
                if (!liveModalForm(form)) return;
                modal.close();
                toast("Feedback saved. Your student can see it now.");
                route();
              } catch (error) {
                formError(form, error.message);
              } finally {
                busy(form, false);
              }
            };
          },
        )),
  );
}
async function teacherAssignment(ctx, id) {
  const assignment = await api(`/teacher/assignments/${id}`);
  if (!ctx.live()) return;
  const recipients = A(assignment.recipients);
  ctx.show(
    `<a class="back-link" href="#/assignments">${icon("back", 14)} All assignments</a>` +
      heading(
        assignment.title,
        `${assignment.target_label || "Classroom assignment"} · Assigned ${date(assignment.created_at)}`,
        "",
        "Learning in progress",
      ) +
      `<div class="stats-grid">${stat("Students assigned", assignment.student_count ?? recipients.length, "users")}${stat("Practices to explore", assignment.problem_count ?? A(assignment.problems).length, "book")}${stat(
        "Attempts submitted",
        recipients.reduce((sum, r) => sum + Number(r.attempt_count || 0), 0),
        "mic",
      )}${stat(
        "Awaiting review",
        recipients.reduce(
          (sum, r) =>
            sum +
            A(r.attempts).filter((a) => a.status === "needs_review").length,
          0,
        ),
        "message",
      )}</div><section class="panel"><div class="panel-heading"><div><h2>What's in this assignment</h2><p>These practice copies stay consistent for every assigned student.</p></div></div><div class="practice-list">${A(
        assignment.problems,
      )
        .map(
          (problem, i) =>
            `<div class="practice-item"><span class="practice-number">${i + 1}</span><div class="practice-copy"><h3>${E(problem.title)}</h3><p>${E(problem.expected_text)}</p></div>${badge(problem.kind)}</div>`,
        )
        .join(
          "",
        )}</div></section><section class="panel"><div class="panel-heading"><div><h2>Student progress & feedback</h2><p>Open a learner's attempts to listen and review.</p></div></div>${recipients.length ? recipients.map((student) => `<div class="recording-row"><div class="panel-heading" style="margin-bottom:10px"><a class="student-cell" href="#/students/${E(student.id)}"><span class="avatar">${E(initials(student.display_name))}</span><div><strong>${E(student.display_name)}</strong><small>${E(student.login_name)}</small></div></a><div class="button-row"><span class="badge">${student.completed_count || 0}/${student.problem_count || assignment.problem_count || 0} complete</span><span class="activity-score">${pct(student.average_score)}</span></div></div>${A(student.attempts).length ? `<details class="collapsible"><summary>${student.attempts.length} ${student.attempts.length === 1 ? "attempt" : "attempts"} · View recordings and feedback</summary>${student.attempts.map((a) => attemptCard(a, true)).join("")}</details>` : '<p class="micro-copy">This learner has not submitted a practice yet.</p>'}</div>`).join("") : empty("No recipients found", "This assignment does not have any enrolled students.", "", true, "users")}</section>`,
  );
}
function skillProgress(progress) {
  const skills = A(progress?.skills);
  if (!skills.length)
    return empty(
      "Your skills will take shape here",
      "Complete a practice to see feedback for that skill. A missing score means it has not been graded, not that you scored zero.",
      "",
      true,
      "chart",
    );
  return (
    skills
      .map((skill) => {
        const scored =
          typeof skill.average_score === "number" &&
          Number.isFinite(skill.average_score);
        const count =
          typeof skill.submitted_problems === "number"
            ? `${skill.submitted_problems} ${skill.submitted_problems === 1 ? "practice" : "practices"} · `
            : "";
        return `<div class="skill-row"><div class="skill-row-header"><span>${E(skillName(skill.skill))}</span><strong>${scored ? pct(skill.average_score) : "Not graded yet"}</strong></div>${scored ? `<div class="progress-track" role="img" aria-label="${E(skillName(skill.skill))}: ${pct(skill.average_score)}"><div class="progress-fill" style="width:${Math.max(0, Math.min(100, skill.average_score * 100))}%"></div></div>` : '<div class="ungraded-bar">Waiting for feedback</div>'}<small>${count}${Number(skill.attempt_count || 0)} ${Number(skill.attempt_count || 0) === 1 ? "attempt" : "attempts"}</small></div>`;
      })
      .join("") +
    '<p class="micro-copy skill-note">Each bar is a separate skill score. Pace, pitch and pronunciation do not have percentage grades.</p>'
  );
}

async function studentDetail(ctx, id) {
  const student = await api(`/teacher/students/${id}`);
  if (!ctx.live()) return;
  const c = student.counts || {},
    attempts = A(student.attempts),
    review = attempts.filter((item) => item.status === "needs_review");
  ctx.show(
    `<a class="back-link" href="#/${student.classroom?.id ? `classrooms/${E(student.classroom.id)}` : "progress"}">${icon("back", 14)} ${student.classroom?.name ? E(student.classroom.name) : "Student progress"}</a>` +
      heading(
        student.display_name,
        `${student.login_name}${student.classroom ? ` · ${student.classroom.name} · ${student.classroom.school_name}` : ""}`,
        `<div class="button-row"><button class="button button-secondary" id="reset-student-password">Reset password</button>${linkButton("assignments/new", "Assign practice", "primary", "plus")}</div>`,
        "Every learner, their own journey",
      ) +
      `<div class="stats-grid">${stat("Assignments received", c.assignments, "clipboard")}${stat("Practices submitted", c.submitted_problems ?? c.completed_problems, "book")}${stat("Attempts made", c.attempts, "mic")}${stat("Average assessed score", pct(student.progress?.average_score), "chart")}</div><div class="two-column"><section class="panel"><div class="panel-heading"><div><h2>Learning by skill</h2><p>Evidence from assessed attempts, including teacher reviews.</p></div></div>${skillProgress(student.progress)}${
        A(student.progress?.weaknesses).length
          ? `<div class="notice amber" style="margin-top:20px"><p><strong>Useful next focus</strong><br>${A(
              student.progress.weaknesses,
            )
              .map((skill) => E(skillName(skill.skill)))
              .join(
                ", ",
              )} currently have assessed averages below 70%. Use the attempts below to decide what to practice next.</p></div>`
          : ""
      }</section><section class="panel"><div class="metric-grid" style="grid-template-columns:1fr 1fr;margin-top:0"><div class="mini-metric"><strong>${Number(c.completed_assignments || 0)}</strong><span>Assignments completed</span></div><div class="mini-metric"><strong>${Number(c.solved_problems || 0)}</strong><span>Practices at 70%+</span></div></div><h2>A little guidance needed</h2>${review.length ? `<p class="muted small">${review.length} ${review.length === 1 ? "attempt is" : "attempts are"} waiting for your review. Add a score and a clear next step below.</p><span class="badge amber">${review.length} awaiting feedback</span>` : empty("All caught up", "New attempts that need your judgment will be highlighted here.", "", true, "checkcircle")}<div class="notice amber" style="margin-top:18px">${icon("mic", 16)}<p>Automatic reading scores measure word match, not phoneme pronunciation. Experimental pitch evidence describes intonation; it does not identify emotion.</p></div></section></div><div class="section-heading"><h2>Practice history</h2><span class="badge">${attempts.length} attempts</span></div>${attempts.length ? attempts.map((attempt) => attemptCard(attempt, true)).join("") : `<section class="panel">${empty("A fresh start", "This student has not submitted any practice yet.", linkButton("assignments/new", "Assign something to try", "secondary", "arrow"), false, "leaf")}</section>`}`,
  );
  ctx.content.querySelector("#reset-student-password").onclick = () =>
    openModal(
      "Reset student password",
      `Set a new password for ${student.display_name}. Existing sessions will be signed out.`,
      `<form><div class="field"><label for="reset-password">New password</label><input id="reset-password" type="password" name="password" minlength="8" maxlength="256" autocomplete="new-password" required placeholder="At least 8 characters"><small>Share this password securely with the student. Their learning history stays in place.</small></div><div class="form-error" role="alert"></div><div class="form-actions"><button type="submit" class="button button-primary">Set new password</button></div></form>`,
      (el) => {
        el.querySelector("form").onsubmit = async (event) => {
          event.preventDefault();
          const form = event.target;
          busy(form, true, "Updating password…");
          formError(form, "");
          try {
            await api(`/teacher/students/${id}/password`, {
              method: "PATCH",
              body: { password: form.querySelector("[name=password]").value },
            });
            if (!ctx.live() || !liveModalForm(form)) return;
            modal.close();
            toast(
              "Password updated. The student can sign in with the new password.",
            );
          } catch (error) {
            if (liveModalForm(form)) formError(form, error.message);
          } finally {
            busy(form, false);
          }
        };
      },
    );
  const historyHeading = [
    ...ctx.content.querySelectorAll(".section-heading"),
  ].find((element) => element.textContent.includes("Practice history"));
  historyHeading.insertAdjacentHTML(
    "beforebegin",
    `<section class="panel student-profile-panel"><div class="panel-heading"><h2>Learning profile</h2><button class="text-button" id="edit-student-profile">Edit details ${icon("arrow", 14)}</button></div>${profileSummary(student.learning_profile || {})}</section><div class="insight-grid"><section class="panel"><div class="panel-heading"><div><h2>Current practice status</h2><p>One slice for each assigned practice.</p></div></div>${completionChart(student.progress?.current_practice_status)}</section><section class="panel"><div class="panel-heading"><div><h2>Practice scores over time</h2><p>Compare one activity type at a time.</p></div></div>${trendPanel(attempts, "student-learning-trend")}</section></div>`,
  );
  ctx.content.querySelector("#edit-student-profile").onclick = () =>
    editStudentProfile(ctx, student);
  bindTrend(ctx.content, attempts);
}
async function teacherProgress(ctx) {
  const classes = A(await api("/teacher/classrooms"));
  const details = await Promise.all(
    classes.map((cls) => api(`/teacher/classrooms/${cls.id}`)),
  );
  if (!ctx.live()) return;
  const students = details.flatMap((cls) =>
    A(cls.students).map((student) => ({ ...student, classroom: cls })),
  );
  ctx.show(
    heading(
      "Every learner has a story.",
      "Open a student to understand their strengths, practice history and next steps.",
      "",
      "Student progress",
    ) +
      `<section class="panel"><div class="panel-heading"><h2>Your learners</h2><span class="badge">${students.length} students</span></div>${students.length ? `<div class="search-field" style="margin-bottom:20px">${icon("search", 16)}<input id="student-search" type="search" placeholder="Find a student or class" aria-label="Find a student or class"></div><div class="table-wrap"><table><thead><tr><th>Student</th><th>Classroom</th><th>School</th><th></th></tr></thead><tbody>${students.map((student) => `<tr data-student-row data-search="${E(`${student.display_name} ${student.login_name} ${student.classroom.name}`.toLowerCase())}"><td><a href="#/students/${E(student.id)}" class="student-cell"><span class="avatar">${E(initials(student.display_name))}</span><div><strong>${E(student.display_name)}</strong><small>${E(student.login_name)}</small></div></a></td><td>${E(student.classroom.name)}</td><td class="muted">${E(student.classroom.school_name)}</td><td><a href="#/students/${E(student.id)}" class="text-button">View progress ${icon("arrow", 14)}</a></td></tr>`).join("")}</tbody></table></div><p class="micro-copy" id="no-student-results" hidden>No students match your search.</p>` : empty("Get to know your learners", "Add students to a classroom to start following their learning journey.", linkButton("classrooms", "Open classrooms", "secondary", "users"), false, "users")}</section>`,
  );
  const input = ctx.content.querySelector("#student-search");
  if (input)
    input.oninput = () => {
      let count = 0;
      ctx.content.querySelectorAll("[data-student-row]").forEach((row) => {
        row.hidden = !row.dataset.search.includes(
          input.value.toLowerCase().trim(),
        );
        if (!row.hidden) count++;
      });
      ctx.content.querySelector("#no-student-results").hidden = count !== 0;
    };
}

async function studentOverview(ctx) {
  const [overview, assignments] = await Promise.all([
    api("/student/overview"),
    api("/student/assignments"),
  ]);
  if (!ctx.live()) return;
  const c = overview.counts || {},
    name = (
      overview.student?.display_name || session().user.display_name
    ).split(" ")[0],
    list = A(assignments),
    next = list.find(
      (item) => (item.completed_count || 0) < item.problem_count,
    );
  ctx.show(
    heading(
      `Hello, ${name}. Let's grow.`,
      overview.classroom
        ? `${overview.classroom.name} · ${overview.classroom.school_name}`
        : "Your own space to practice, explore and find your voice.",
      "",
      "One step at a time",
    ) +
      `<section class="hero"><div class="hero-copy"><div class="eyebrow">Your voice is worth hearing</div><h2>Every try is a step<br>towards confidence.</h2><p>Listen to your teacher, give it a go, and learn something new about what you can do.</p>${linkButton(next ? `assignments/${next.id}` : "assignments", next ? "Continue your learning" : "Explore your assignments", "amber", "arrow")}</div><div class="hero-art">${art()}</div></section><div class="stats-grid">${stat("Your assignments", c.assignments, "clipboard")}${stat("Practices submitted", c.submitted_problems ?? c.completed_problems, "book")}${stat("Times you tried", c.attempts, "mic")}${stat("Average assessed score", pct(overview.progress?.average_score), "chart")}</div><div class="section-heading"><h2>Ready for your next step?</h2><a class="text-button" href="#/assignments">All assignments ${icon("arrow", 14)}</a></div>${
        list.length
          ? `<div class="card-grid">${list
              .slice(0, 3)
              .map((item) => assignmentCard(item, true))
              .join("")}</div>`
          : `<section class="panel">${empty("Something good is on its way", "Your teacher will share assignments here. Come back when your first practice is ready.", "", true, "leaf")}</section>`
      }<div class="section-heading"><h2>Little signs of progress</h2></div><div class="two-column"><section class="panel"><div class="panel-heading"><h3>Growing skills</h3>${icon("chart", 18)}</div>${skillProgress(overview.progress)}</section><section class="panel"><div class="panel-heading"><h3>Your latest feedback</h3>${icon("message", 18)}</div>${activity(overview.recent_feedback, false)}</section></div>`,
  );
  const nextSection = ctx.content.querySelector(".section-heading");
  nextSection.insertAdjacentHTML(
    "beforebegin",
    `<section class="panel overview-completion"><div class="panel-heading"><div><h2>Your practice at a glance</h2><p>See what is ready, waiting and still to try.</p></div><a class="text-button" href="#/history">Explore your progress ${icon("arrow", 14)}</a></div>${completionChart(overview.progress?.current_practice_status)}</section>`,
  );
}
async function studentAssignments(ctx) {
  const list = A(await api("/student/assignments"));
  if (!ctx.live()) return;
  ctx.show(
    heading(
      "A little practice, a little growth.",
      "Your teacher has chosen these challenges for you. Take them at your own pace.",
      "",
      "My assignments",
    ) +
      (list.length
        ? `<div class="card-grid">${list.map((item) => assignmentCard(item, true)).join("")}</div>`
        : `<section class="panel">${empty("Your next adventure is on its way", "Your teacher has not assigned any practices yet. When they do, you will find them right here.", "", false, "clipboard")}</section>`),
  );
}
function latestAttempt(problem) {
  return A(problem.attempts)
    .slice()
    .sort((a, b) =>
      String(b.created_at).localeCompare(String(a.created_at)),
    )[0];
}
function completedPractice(problem) {
  const settled = latestAttempt({
    attempts: A(problem.attempts).filter((attempt) =>
      ["completed", "needs_review"].includes(attempt.status),
    ),
  });
  return settled?.status === "completed";
}
async function studentAssignment(ctx, id) {
  const assignment = await api(`/student/assignments/${id}`);
  if (!ctx.live()) return;
  const problems = A(assignment.problems),
    complete = problems.filter(completedPractice).length;
  ctx.show(
    `<a class="back-link" href="#/assignments">${icon("back", 14)} My assignments</a>` +
      heading(
        assignment.title,
        "One thoughtful practice at a time. Listen, explore, and give it a try.",
        "",
        "Made for your learning",
      ) +
      `<section class="panel" style="margin-bottom:23px"><div class="panel-heading"><h3>Your journey through this assignment</h3><span class="badge ${complete === problems.length ? "green" : ""}">${complete}/${problems.length} completed</span></div><div class="progress-track"><div class="progress-fill" style="width:${problems.length ? (complete / problems.length) * 100 : 0}%"></div></div><p class="micro-copy">Attempts waiting for your teacher's review are saved and will be marked complete after feedback.</p></section><div class="practice-list">${problems
        .map((problem, index) => {
          const latest = latestAttempt(problem);
          return `<article class="practice-item"><span class="practice-number">${completedPractice(problem) ? icon("check", 18) : index + 1}</span><div class="practice-copy"><h3>${E(problem.title)}</h3><p>${kindName(problem.kind)}${A(problem.attempts).length ? ` · ${problem.attempts.length} ${problem.attempts.length === 1 ? "try" : "tries"}` : ""}</p></div>${latest ? statusBadge(latest.status) : badge(problem.kind)}<a class="button button-${latest ? "secondary" : "primary"} button-small" href="#/practice/${E(id)}/${E(problem.id)}">${latest ? "Practice again" : "Let’s try"} ${icon("arrow", 14)}</a></article>`;
        })
        .join(
          "",
        )}</div>${!problems.length ? `<section class="panel">${empty("No practices in this assignment", "Ask your teacher to check this assignment.", "", false, "book")}</section>` : ""}`,
  );
}

function makeRequestId() {
  if (crypto.randomUUID) return crypto.randomUUID();
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  const hex = [...bytes].map((v) => v.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}
async function practice(ctx, assignmentId, itemId) {
  const assignment = await api(`/student/assignments/${assignmentId}`);
  if (!ctx.live()) return;
  const problems = A(assignment.problems),
    index = problems.findIndex((p) => p.id === itemId),
    problem = problems[index];
  if (!problem)
    throw new Error("This practice is not part of your assignment.");
  const payload = problem.payload || {},
    previous = A(problem.attempts);
  let input = "";
  if (problem.kind === "read_aloud")
    input = `${problem.reference_audio_url ? `<div class="panel-heading" style="margin-top:22px"><h3>${icon("sound", 15)} Listen to your teacher</h3></div>${audioPlayer(problem.reference_audio_url, "Your teacher’s reference recording")}` : '<div class="notice amber">The teacher reference recording is unavailable. Ask your teacher to check this practice.</div>'}${payload.expression ? `<div class="notice amber" style="margin-top:17px">${icon("message", 16)}<p>${E(payload.expression)}</p></div>` : ""}<div class="section-heading"><h3>Now it's your turn.</h3></div><div id="student-recorder" class="recorder"></div>`;
  if (problem.kind === "choice")
    input = `<div class="question-options">${A(payload.options)
      .map(
        (option, i) =>
          `<label class="choice-option"><input type="radio" name="answer" value="${E(option.id)}" required><span class="option-letter">${String.fromCharCode(65 + i)}</span><span>${E(option.text)}</span></label>`,
      )
      .join("")}</div>`;
  if (problem.kind === "matching")
    input = `<p class="muted small">Find the partner for each item. Use each answer once.</p><div class="form-grid">${A(
      payload.left,
    )
      .map(
        (left, i) =>
          `<div class="field full"><label for="match-${i}">${E(left.text)}</label><select id="match-${i}" data-match-left="${E(left.id)}" required><option value="">Choose its matching partner</option>${A(
            payload.right,
          )
            .map(
              (right) =>
                `<option value="${E(right.id)}">${E(right.text)}</option>`,
            )
            .join("")}</select></div>`,
      )
      .join("")}</div>`;
  if (problem.kind === "meaning")
    input =
      '<div class="field"><label for="meaning-answer">What does this mean to you?</label><textarea id="meaning-answer" name="answer" required maxlength="5000" placeholder="Explain the idea in your own words. You do not have to use the exact same sentence." style="min-height:150px"></textarea><small>Focus on the idea. A related meaning can show understanding too.</small></div>';
  ctx.show(
    `<div class="practice-content"><a class="back-link" href="#/assignments/${E(assignmentId)}">${icon("back", 14)} ${E(assignment.title)}</a><div class="page-heading"><div><div class="eyebrow">Practice ${index + 1} of ${problems.length}</div><h1>${E(problem.title)}</h1></div>${badge(problem.kind)}</div><section class="panel"><form id="practice-form"><div class="prompt-large">${E(problem.expected_text)}</div>${problem.teaching_notes ? `<div class="notice" style="margin-bottom:24px">${icon("leaf", 17)}<p><strong>A note from your teacher</strong><br>${E(problem.teaching_notes)}</p></div>` : ""}${input}<div class="form-error" role="alert"></div><div class="practice-footer"><span class="step-label">${problem.kind === "read_aloud" ? "Take a breath. Speak naturally. Be yourself." : "Every thoughtful try helps you grow."}</span><button type="submit" class="button button-primary">${problem.kind === "read_aloud" ? "Send my recording" : "Check my answer"} ${icon("arrow", 15)}</button></div></form></section>${previous.length ? `<div class="section-heading"><h2>Your previous tries</h2><span class="badge">${previous.length}</span></div>${previous.map((item) => attemptCard({ ...item, problem_title: problem.title, kind: problem.kind })).join("")}` : ""}</div>`,
  );
  const form = ctx.content.querySelector("#practice-form");
  let recorder = null,
    requestId = makeRequestId(),
    lastFingerprint = null;
  if (problem.kind === "read_aloud")
    recorder = mountRecorder(
      ctx.content.querySelector("#student-recorder"),
      scope,
      {
        onChange: () => {
          requestId = makeRequestId();
          lastFingerprint = null;
        },
      },
    );
  if (problem.kind === "matching")
    form.querySelectorAll("[data-match-left]").forEach(
      (select) =>
        (select.onchange = () => {
          const selects = [...form.querySelectorAll("[data-match-left]")];
          const chosen = selects.map((item) => item.value).filter(Boolean);
          selects.forEach((item) =>
            [...item.options].forEach((option) => {
              option.disabled =
                !!option.value &&
                option.value !== item.value &&
                chosen.includes(option.value);
            }),
          );
        }),
    );
  form.onsubmit = async (event) => {
    event.preventDefault();
    formError(form, "");
    if (recorder?.isRecording) {
      formError(form, "Finish your recording before sending it.");
      return;
    }
    if (recorder && !recorder.file) {
      formError(form, "Record your voice or upload an audio file first.");
      return;
    }
    let answer;
    if (problem.kind === "choice") answer = new FormData(form).get("answer");
    if (problem.kind === "meaning") {
      answer = String(new FormData(form).get("answer")).trim();
      if (!answer) {
        formError(form, "Write the meaning in your own words before sending.");
        return;
      }
    }
    if (problem.kind === "matching") {
      answer = Object.fromEntries(
        [...form.querySelectorAll("[data-match-left]")].map((select) => [
          select.dataset.matchLeft,
          select.value,
        ]),
      );
      if (new Set(Object.values(answer)).size !== Object.keys(answer).length) {
        formError(form, "Use each matching partner only once.");
        return;
      }
    }
    const fingerprint = recorder
      ? `${recorder.file.name}:${recorder.file.size}:${recorder.file.lastModified}`
      : JSON.stringify(answer);
    if (lastFingerprint !== null && lastFingerprint !== fingerprint)
      requestId = makeRequestId();
    lastFingerprint = fingerprint;
    busy(
      form,
      true,
      recorder ? "Sending your recording…" : "Sending your answer…",
    );
    lockEditing(form, true);
    try {
      const base = `/student/assignments/${assignmentId}/problems/${itemId}`;
      let result;
      if (recorder) {
        const body = new FormData();
        body.append("file", recorder.file);
        body.append("request_id", requestId);
        result = await api(`${base}/recordings`, { method: "POST", body });
      } else
        result = await api(`${base}/attempts`, {
          method: "POST",
          body: { request_id: requestId, answer },
        });
      if (!ctx.live()) return;
      sessionStorage.setItem(
        `vachak.attempt.${result.id}`,
        JSON.stringify({
          assignmentId,
          itemId,
          nextId: problems[index + 1]?.id || null,
          title: problem.title,
          kind: problem.kind,
        }),
      );
      go(`attempts/${result.id}`);
    } catch (error) {
      formError(form, error.message);
    } finally {
      busy(form, false);
      lockEditing(form, false);
    }
  };
}

function readingMetrics(result, status) {
  if (!result || typeof result !== "object") return "";
  const metrics = [];
  if (typeof result.word_accuracy === "number")
    metrics.push(["Word match", pct(result.word_accuracy)]);
  if (typeof result.word_coverage === "number")
    metrics.push(["Word coverage", pct(result.word_coverage)]);
  if (typeof result.pace?.words_per_minute === "number")
    metrics.push([
      "Words per minute",
      Math.round(result.pace.words_per_minute),
    ]);
  const alignment = A(result.alignment),
    errors = alignment.filter((item) => item.operation !== "match");
  return `${metrics.length ? `<div class="metric-grid">${metrics.map(([label, value]) => `<div class="mini-metric"><strong>${E(value)}</strong><span>${E(label)}</span></div>`).join("")}</div>` : ""}${result.transcript ? `<div class="section-heading"><h3>What the speech model heard</h3></div><div class="quote" style="font-size:17px">${E(result.transcript)}</div>` : ""}${errors.length ? `<details class="collapsible"><summary>Explore word differences (${errors.length})</summary><div class="table-wrap" style="margin-top:12px"><table><thead><tr><th>Written word</th><th>Heard word</th><th>Difference</th></tr></thead><tbody>${errors.map((item) => `<tr><td>${E(item.expected || "—")}</td><td>${E(item.spoken || "—")}</td><td class="muted">${E({ substitution: "Different word", deletion: "Not heard", insertion: "Extra word" }[item.operation] || item.operation)}</td></tr>`).join("")}</tbody></table></div></details>` : ""}${A(result.pauses?.word_gaps).length ? `<details class="collapsible"><summary>Pauses between words (${result.pauses.word_gaps.length})</summary><div class="table-wrap" style="margin-top:12px"><table><thead><tr><th>After word</th><th>Pause</th></tr></thead><tbody>${result.pauses.word_gaps.map((item) => `<tr><td>${E(item.after_word)}</td><td>${Number(item.seconds || 0).toFixed(2)} seconds</td></tr>`).join("")}</tbody></table></div></details>` : ""}${typeof result.reference_comparison?.pace_ratio === "number" ? `<p class="micro-copy">Your estimated pace is ${Number(result.reference_comparison.pace_ratio).toFixed(2)}× your teacher's reference. A different natural pace is not automatically a mistake.</p>` : ""}${pitchEvidence(result.pitch)}<div class="notice amber" style="margin-top:22px">${icon("mic", 16)}<p>${status !== "completed" ? "These are ungraded estimates pending review. " : ""}Word match comes from speech transcription and may miss accents or unclear audio. It is not a phoneme pronunciation score. Pitch evidence is experimental and does not identify mood or emotion.</p></div>`;
}
function pitchEvidence(pitch) {
  if (!pitch || pitch.status === "not_assessed") return "";
  const heading =
    '<div class="section-heading"><h3>The shape of your voice</h3><span class="badge amber">Experimental · ungraded</span></div>';
  if (pitch.status !== "available")
    return `${heading}<div class="notice"><p>There is not enough clear voice audio to show a reliable pitch line. Your recording is saved.</p></div>${pitch.interpretation ? `<details class="collapsible"><summary>About this analysis</summary><p class="micro-copy">${E(pitch.interpretation)}</p></details>` : ""}`;
  const frames = A(pitch.frames),
    voiced = frames.filter(
      (frame) => frame.voiced && Number.isFinite(frame.relative_semitones),
    );
  const maxTime = Math.max(
    1,
    ...frames.map((frame) => Number(frame.time_seconds) || 0),
  );
  const range = Math.max(
    6,
    Math.ceil(
      Math.max(
        0,
        ...voiced.map((frame) => Math.abs(frame.relative_semitones)),
      ) + 1,
    ),
  );
  const y = (value) => 160 - ((value + range) / (range * 2)) * 130;
  let path = "",
    open = false;
  frames.forEach((frame) => {
    if (!frame.voiced || !Number.isFinite(frame.relative_semitones)) {
      open = false;
      return;
    }
    const x =
      48 + (Math.max(0, Number(frame.time_seconds) || 0) / maxTime) * 582;
    path += `${open ? "L" : "M"}${x.toFixed(2)},${y(frame.relative_semitones).toFixed(2)} `;
    open = true;
  });
  const chart = `<div class="pitch-chart"><svg viewBox="0 0 660 198" role="img" aria-label="Experimental pitch contour. Height shows semitones above or below this speaker's median; horizontal position shows time.">${[-range, 0, range].map((value) => `<line x1="48" y1="${y(value)}" x2="630" y2="${y(value)}" stroke="${value === 0 ? "#b5c5aa" : "#e2e9dc"}" stroke-dasharray="${value === 0 ? "4 4" : "0"}"/><text x="37" y="${y(value) + 4}" text-anchor="end" fill="#8b9b7d" font-size="11">${value > 0 ? "+" : ""}${value}</text>`).join("")}<path d="${path}" fill="none" stroke="#477849" stroke-width="2.1" stroke-linejoin="round"/><text x="48" y="185" fill="#8b9b7d" font-size="11">0s</text><text x="630" y="185" text-anchor="end" fill="#8b9b7d" font-size="11">${maxTime.toFixed(1)}s</text><text x="339" y="185" text-anchor="middle" fill="#8b9b7d" font-size="10">Time in recording</text><text x="48" y="15" fill="#8b9b7d" font-size="10">Semitones relative to the speaker's median</text></svg></div>`;
  const summary = pitch.summary || {},
    comparison = pitch.reference_comparison || {},
    points = A(comparison.points);
  return `${heading}${voiced.length ? chart : ""}<div class="metric-grid">${[
    [
      "Median pitch",
      Number.isFinite(summary.median_f0_hz)
        ? `${Math.round(summary.median_f0_hz)} Hz`
        : "—",
    ],
    [
      "Pitch span",
      Number.isFinite(summary.range_semitones)
        ? `${summary.range_semitones.toFixed(1)} st`
        : "—",
    ],
    [
      "Voiced audio",
      Number.isFinite(summary.voiced_seconds)
        ? `${summary.voiced_seconds.toFixed(1)}s`
        : "—",
    ],
  ]
    .map(
      ([label, value]) =>
        `<div class="mini-metric"><strong>${E(value)}</strong><span>${E(label)}</span></div>`,
    )
    .join(
      "",
    )}</div><p class="micro-copy">The line shows how your voice rises and falls. This is practice guidance, not a grade.</p><details class="collapsible"><summary>About this analysis</summary><p class="micro-copy">${E(pitch.interpretation || "This contour describes pitch movement within the recording. Different voices naturally have different pitch ranges.")}</p></details>${points.length ? `<details class="collapsible"><summary>Compare expression word by word</summary><p class="micro-copy">Each voice is centered on its own median. These measurements describe contour differences; they are not accuracy or emotion grades.</p><div class="table-wrap" style="margin-top:12px"><table><thead><tr><th>Word</th><th>Student</th><th>Reference</th><th>Difference</th></tr></thead><tbody>${points.map((point) => `<tr><td>${E(point.word)}</td><td>${Number(point.student_semitones).toFixed(1)} st</td><td>${Number(point.reference_semitones).toFixed(1)} st</td><td>${Number(point.difference_semitones).toFixed(1)} st</td></tr>`).join("")}</tbody></table></div><p class="micro-copy">${E(comparison.interpretation || "Word alignment and pitch estimation can make mistakes. Use listening and teacher judgment alongside these measurements.")}</p></details>` : ""}`;
}
async function attemptResult(ctx, id) {
  let context = null;
  try {
    context = JSON.parse(
      sessionStorage.getItem(`vachak.attempt.${id}`) || "null",
    );
  } catch {
    /* Navigation remains available without session context. */
  }
  const attempt = await api(`/student/attempts/${id}`);
  if (!ctx.live()) return;
  const isReading =
      (attempt.kind || context?.kind) === "read_aloud" || attempt.result?.pitch,
    completed =
      attempt.status === "completed" && typeof attempt.score === "number",
    pending = attempt.status === "pending";
  const display = attempt.display_feedback || {};
  const title =
    display.headline ||
    (pending
      ? "Your practice is being heard."
      : attempt.status === "needs_review"
        ? "Your teacher will take a look."
        : attempt.status === "failed"
          ? "Your attempt has been saved."
          : completed && attempt.score >= 0.85
            ? "A thoughtful step forward."
            : "Every try teaches you something.");
  const subtitle =
    display.summary ||
    (pending
      ? "Your answer is saved. We are preparing your feedback."
      : attempt.status === "needs_review"
        ? "Your teacher will help check this attempt before a score is given."
        : attempt.status === "failed"
          ? "Your recording is saved. Automatic feedback was unavailable; your teacher can still help."
          : isReading
            ? "Listen again, notice one small thing, and give the sentence another try."
            : "Keep the feedback in mind as you try the next practice.");
  const teacherReview = attempt.result?.teacher_review;
  const textTips = !isReading ? A(display.next_steps).slice(0, 2) : [];
  ctx.show(
    `<div class="practice-content feedback-page"><a class="back-link" href="#/${context ? `assignments/${E(context.assignmentId)}` : "assignments"}">${icon("back", 14)} Back to assignments</a><section class="panel"><div class="result-hero"><div class="score-orb">${pending ? '<span class="spinner"></span>' : completed ? `<strong>${pct(attempt.score)}</strong><span>${teacherReview ? "Teacher score" : isReading ? "Word match" : "Practice score"}</span>` : icon(attempt.status === "needs_review" ? "message" : "leaf", 34)}</div>${statusBadge(attempt.status)}<h2 style="margin-top:18px">${E(title)}</h2><p>${E(subtitle)}</p></div>${attempt.problem_title || context?.title ? `<p class="eyebrow" style="text-align:center">${E(attempt.problem_title || context.title)}</p>` : ""}${teacherReview ? `<div class="teacher-guidance"><span class="eyebrow">A note from your teacher</span><p>${E(attempt.feedback || teacherReview.feedback)}</p></div>` : ""}${isReading && !pending ? simpleReadingFeedback(attempt) : ""}${textTips.length ? `<div class="next-step-box"><span class="eyebrow">Your next small step</span>${textTips.map((tip) => `<p>${E(tip)}</p>`).join("")}</div>` : ""}${attempt.audio_url ? `<div class="section-heading"><h3>Listen and try together</h3></div><div class="listen-grid">${attempt.reference_audio_url ? `<div class="listening-card"><span class="dimension-label">Your teacher's example</span>${audioPlayer(attempt.reference_audio_url, "Teacher reference recording")}</div>` : ""}<div class="listening-card"><span class="dimension-label">Your recording</span>${audioPlayer(attempt.audio_url, "Your submitted recording")}</div></div>` : ""}${isReading && !pending ? `<details class="collapsible technical-evidence"><summary>Detailed analysis <span class="muted">(optional)</span></summary><p class="micro-copy">These measurements support listening and teacher judgment. They are not a separate pronunciation or emotion assessment.</p>${readingMetrics(attempt.result, attempt.status)}</details>` : ""}${!isReading && !display.summary && attempt.feedback && !teacherReview ? `<div class="feedback-box">${E(attempt.feedback)}</div>` : ""}<div id="poll-note" class="micro-copy" style="text-align:center"></div><div class="form-actions" style="justify-content:center;flex-wrap:wrap">${context ? linkButton(`practice/${context.assignmentId}/${context.itemId}`, "Try this practice again", "secondary") : linkButton("history", "My progress", "secondary")}${context?.nextId ? linkButton(`practice/${context.assignmentId}/${context.nextId}`, "Next practice", "primary", "arrow") : linkButton(context ? `assignments/${context.assignmentId}` : "assignments", "Back to my learning", "primary", "arrow")}</div></section></div>`,
  );
  if (
    ["failed", "needs_review"].includes(attempt.status) &&
    !attempt.reviewed_at &&
    ["read_aloud", "meaning"].includes(attempt.kind || context?.kind)
  ) {
    const actions = ctx.content.querySelector(".form-actions");
    actions.insertAdjacentHTML(
      "beforebegin",
      '<div class="button-row" style="justify-content:center;margin-top:20px"><button type="button" class="text-button" id="retry-analysis">Recheck automatic analysis</button></div>',
    );
    ctx.content.querySelector("#retry-analysis").onclick = async (event) => {
      const button = event.currentTarget;
      button.disabled = true;
      button.textContent = "Queuing analysis…";
      try {
        await api(`/student/attempts/${id}/retry-analysis`, { method: "POST" });
        if (ctx.live()) route();
      } catch (error) {
        if (ctx.live()) {
          ctx.content.querySelector("#poll-note").textContent = error.message;
          button.disabled = false;
          button.textContent = "Recheck automatic analysis";
        }
      }
    };
  }
  if (pending) {
    const started = Date.now();
    const poll = async () => {
      if (!ctx.live()) return;
      try {
        const fresh = await api(`/student/attempts/${id}`);
        if (!ctx.live()) return;
        if (fresh.status !== "pending") {
          route();
          return;
        }
        if (Date.now() - started > 120000) {
          ctx.content.querySelector("#poll-note").innerHTML =
            'Analysis is taking a little longer. You can come back later; your attempt is saved. <button class="text-button" id="refresh-result">Check again</button>';
          ctx.content.querySelector("#refresh-result").onclick = route;
          return;
        }
        routeTimers.push(setTimeout(poll, 2500));
      } catch (error) {
        if (ctx.live()) {
          ctx.content.querySelector("#poll-note").textContent =
            `Could not refresh feedback: ${error.message} Open this result again to retry.`;
        }
      }
    };
    routeTimers.push(setTimeout(poll, 2000));
  }
}
async function studentHistory(ctx) {
  const [overview, list] = await Promise.all([
    api("/student/overview"),
    api("/student/assignments"),
  ]);
  const details = await Promise.all(
    A(list).map((item) => api(`/student/assignments/${item.id}`)),
  );
  if (!ctx.live()) return;
  const attempts = details
    .flatMap((assignment) =>
      A(assignment.problems).flatMap((problem) =>
        A(problem.attempts).map((item) => ({
          ...item,
          problem_title: problem.title,
          kind: problem.kind,
          assignmentId: assignment.id,
          itemId: problem.id,
        })),
      ),
    )
    .sort((a, b) => String(b.created_at).localeCompare(String(a.created_at)));
  attempts.forEach((item) =>
    sessionStorage.setItem(
      `vachak.attempt.${item.id}`,
      JSON.stringify({
        assignmentId: item.assignmentId,
        itemId: item.itemId,
        title: item.problem_title,
        kind: item.kind,
      }),
    ),
  );
  const c = overview.counts || {};
  ctx.show(
    heading(
      "Look how far you’re growing.",
      "Every attempt is a little piece of your learning story.",
      "",
      "My progress",
    ) +
      `<div class="stats-grid">${stat("Times you tried", c.attempts, "mic")}${stat("Practices submitted", c.submitted_problems ?? c.completed_problems, "book")}${stat("Assignments completed", c.completed_assignments, "checkcircle")}${stat("Average assessed score", pct(overview.progress?.average_score), "chart")}</div><section class="panel"><div class="panel-heading"><h2>Your growing skills</h2>${icon("leaf", 20)}</div>${skillProgress(overview.progress)}</section><div class="section-heading"><h2>Your practice story</h2><span class="badge">${attempts.length} attempts</span></div>${attempts.length ? attempts.map((item) => attemptCard(item)).join("") : `<section class="panel">${empty("Your first step is waiting", "Try a practice from your teacher, then come back here to see what you learned.", linkButton("assignments", "Find a practice", "primary", "arrow"), false, "leaf")}</section>`}`,
  );
  const skillsPanel = ctx.content.querySelector(".panel");
  skillsPanel.insertAdjacentHTML(
    "beforebegin",
    `<div class="insight-grid"><section class="panel"><div class="panel-heading"><div><h2>Current practice status</h2><p>Every assigned practice has its own place.</p></div></div>${completionChart(overview.progress?.current_practice_status)}</section><section class="panel"><div class="panel-heading"><div><h2>Practice scores over time</h2><p>Choose an activity to follow its scores.</p></div></div>${trendPanel(attempts, "my-learning-trend")}</section></div>`,
  );
  bindTrend(ctx.content, attempts);
}

window.addEventListener("hashchange", route);
window.addEventListener("session-expired", () => {
  if (!session()) return;
  saveSession(null);
  cleanup();
  toast("Your session has expired. Sign in again to continue.", true);
  go("login");
});
window.addEventListener("pagehide", () => scope.dispose());
modal.addEventListener("click", (event) => {
  if (event.target === modal) {
    const rect = modal.getBoundingClientRect();
    if (
      event.clientX < rect.left ||
      event.clientX > rect.right ||
      event.clientY < rect.top ||
      event.clientY > rect.bottom
    )
      modal.close();
  }
});
async function start() {
  if (session()?.access_token) {
    try {
      const user = await api("/auth/me");
      saveSession({ ...session(), user });
    } catch (error) {
      if (error.status !== 0) saveSession(null);
      else if (!session()?.user) {
        saveSession(null);
        toast(error.message, true);
      }
    }
  }
  if (session()?.user) shell();
  await route();
}
start();
