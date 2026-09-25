const escape = (value) =>
  String(value ?? "").replace(
    /[&<>"']/g,
    (char) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[
        char
      ],
  );
const list = (value) => (Array.isArray(value) ? value : []);
const percentage = (value) =>
  typeof value === "number" &&
  Number.isFinite(value) &&
  value >= 0 &&
  value <= 1
    ? `${Math.round(value * 100)}%`
    : "Not graded";

export function assessedScore(attempt) {
  const score = attempt?.score;
  return attempt?.status === "completed" &&
    typeof score === "number" &&
    Number.isFinite(score) &&
    score >= 0 &&
    score <= 1
    ? score
    : null;
}

export function completionChart(status) {
  const unavailable =
    '<div class="empty compact"><h3>Practice status is not available yet.</h3><p>Your assignment list still shows the practices you can work on. Refresh this page when progress information is available.</p></div>';
  const keys = ["graded", "pending", "needs_review", "not_started"];
  if (
    !status ||
    ![...keys, "total"].every(
      (key) => Number.isSafeInteger(status[key]) && status[key] >= 0,
    )
  )
    return unavailable;
  const total = status.total;
  const segments = [
    ["graded", "Feedback ready", "#537c52"],
    ["pending", "Being checked", "#e6bd62"],
    ["needs_review", "Needs attention", "#b791aa"],
    ["not_started", "Not started", "#dfe6d8"],
  ].map(([key, label, color]) => ({
    key,
    label,
    color,
    value: status[key],
  }));
  if (segments.reduce((sum, item) => sum + item.value, 0) !== total)
    return unavailable;
  const valid = total > 0;
  let offset = 0;
  const circles = valid
    ? segments
        .filter((item) => item.value > 0)
        .map((item) => {
          const amount = (item.value / total) * 100;
          const circle = `<circle cx="85" cy="85" r="64" pathLength="100" fill="none" stroke="${item.color}" stroke-width="17" stroke-dasharray="${amount} ${100 - amount}" stroke-dashoffset="${-offset}" transform="rotate(-90 85 85)"/>`;
          offset += amount;
          return circle;
        })
        .join("")
    : "";
  return `<div class="completion-layout"><div class="completion-donut"><svg viewBox="0 0 170 170" role="img" aria-label="${valid ? escape(segments.map((item) => `${item.value} ${item.label.toLowerCase()}`).join(", ")) : "No assigned practices yet"}"><circle cx="85" cy="85" r="64" fill="none" stroke="#edf1e7" stroke-width="17"/>${circles}<text x="85" y="83" text-anchor="middle" class="donut-value">${valid ? `${segments[0].value}/${total}` : "—"}</text><text x="85" y="104" text-anchor="middle" class="donut-label">${valid ? "feedback ready" : "no practices yet"}</text></svg></div><ul class="chart-legend">${segments.map((item) => `<li><span class="legend-dot" style="--legend-color:${item.color}"></span><span>${escape(item.label)}</span><strong>${valid ? `${item.value} · ${Math.round((item.value / total) * 100)}%` : "—"}</strong></li>`).join("")}</ul></div><p class="micro-copy">${valid ? "Each assigned practice appears once, using its latest attempt. The slices show practice status, not speaking abilities." : "Your chart will fill in when practices are assigned. Nothing is scored until you submit your work."}</p>`;
}

export function trendPanel(attempts, id = "learning-trend") {
  const kinds = [
    ["read_aloud", "Reading"],
    ["choice", "Word quizzes"],
    ["matching", "Matching"],
    ["meaning", "Meaning"],
  ];
  const present = kinds.filter(([kind]) =>
    list(attempts).some((item) => item.kind === kind),
  );
  if (!present.length)
    return '<div class="empty compact"><h3>Your learning story starts with a try.</h3><p>As you practise, a separate chart for each activity will show your recorded scores over time.</p></div>';
  return `<div class="trend-panel" id="${escape(id)}"><div class="tabs trend-tabs" role="tablist" aria-label="Choose a practice type">${present.map(([kind, label], index) => `<button type="button" role="tab" aria-selected="${index === 0}" aria-controls="${escape(id)}-plot" id="${escape(id)}-${kind}" class="tab${index === 0 ? " active" : ""}" data-trend-kind="${kind}" tabindex="${index === 0 ? "0" : "-1"}">${label}</button>`).join("")}</div><div class="trend-body" id="${escape(id)}-plot" role="tabpanel"></div></div>`;
}

export function bindTrend(container, attempts) {
  container.querySelectorAll(".trend-panel").forEach((panel) => {
    const buttons = [...panel.querySelectorAll("[data-trend-kind]")],
      body = panel.querySelector(".trend-body");
    const select = (button) => {
      buttons.forEach((item) => {
        const selected = item === button;
        item.classList.toggle("active", selected);
        item.setAttribute("aria-selected", String(selected));
        item.tabIndex = selected ? 0 : -1;
      });
      body.setAttribute("aria-labelledby", button.id);
      const all = list(attempts)
        .filter((item) => item.kind === button.dataset.trendKind)
        .slice()
        .sort((a, b) =>
          String(a.created_at).localeCompare(String(b.created_at)),
        );
      const items = all.slice(-20),
        graded = items.filter((item) => assessedScore(item) !== null),
        width = 650,
        height = 220,
        left = 40,
        right = 625,
        top = 25,
        bottom = 172;
      const x = (index) =>
          items.length === 1
            ? (left + right) / 2
            : left + (index / (items.length - 1)) * (right - left),
        y = (score) =>
          bottom - Math.max(0, Math.min(1, score)) * (bottom - top);
      let path = "",
        open = false;
      const points = items
        .map((item, index) => {
          const scored = assessedScore(item) !== null;
          if (!scored) {
            open = false;
            return `<circle cx="${x(index)}" cy="${bottom + 13}" r="3" fill="#b79caf"><title>Attempt ${all.length - items.length + index + 1}: awaiting a grade</title></circle>`;
          }
          path += `${open ? "L" : "M"}${x(index)},${y(item.score)} `;
          open = true;
          const label = `Attempt ${all.length - items.length + index + 1}: ${percentage(item.score)}${item.reviewed_at || item.result?.teacher_review ? " · teacher reviewed" : ""}`;
          return item.reviewed_at || item.result?.teacher_review
            ? `<path d="M${x(index)},${y(item.score) - 5} l5,5 -5,5 -5,-5 z" fill="#b791aa"><title>${escape(label)}</title></path>`
            : `<circle cx="${x(index)}" cy="${y(item.score)}" r="4" fill="#fff" stroke="#537c52" stroke-width="2"><title>${escape(label)}</title></circle>`;
        })
        .join("");
      const description = `${button.textContent}: ${graded.length} graded attempts, ${items.length - graded.length} ungraded among the latest ${items.length} attempts.`;
      body.innerHTML = `<svg class="trend-chart" viewBox="0 0 ${width} ${height}" role="img" aria-label="${escape(description)}">${[0, 0.5, 1].map((score) => `<line x1="${left}" y1="${y(score)}" x2="${right}" y2="${y(score)}" stroke="#e3e9db"/><text x="${left - 10}" y="${y(score) + 4}" text-anchor="end" fill="#839576" font-size="10">${Math.round(score * 100)}%</text>`).join("")}<path d="${path}" fill="none" stroke="#537c52" stroke-width="2"/>${points}<text x="${left}" y="210" fill="#839576" font-size="10">Earlier attempts</text><text x="${right}" y="210" text-anchor="end" fill="#839576" font-size="10">Most recent</text></svg><p class="trend-markers">○ Automatic feedback &nbsp; ◆ Teacher review</p><div class="trend-summary"><span>${graded.length} graded · ${items.length - graded.length} waiting or ungraded</span><strong>${graded.length ? `Latest score ${percentage(graded[graded.length - 1].score)}` : "No score yet"}</strong></div><p class="micro-copy">${button.dataset.trendKind === "read_aloud" ? "Reading shows automatic word-match scores or teacher-reviewed scores. " : ""}Each dot is one attempt in this activity type. Scores come from different practices.${all.length > 20 ? " Showing the latest 20 attempts." : ""}</p><details class="collapsible"><summary>Read the scores as a table</summary><div class="table-wrap"><table><thead><tr><th>Attempt</th><th>Practice</th><th>Score</th><th>Feedback</th></tr></thead><tbody>${items.map((item, index) => `<tr><td>${all.length - items.length + index + 1}</td><td>${escape(item.problem_title || "Practice")}</td><td>${percentage(assessedScore(item))}</td><td>${item.reviewed_at || item.result?.teacher_review ? "Teacher review" : assessedScore(item) !== null ? "Automatic" : "Awaiting feedback"}</td></tr>`).join("")}</tbody></table></div></details>`;
    };
    buttons.forEach((button, index) => {
      button.onclick = () => select(button);
      button.onkeydown = (event) => {
        let next;
        if (event.key === "ArrowRight") next = (index + 1) % buttons.length;
        else if (event.key === "ArrowLeft")
          next = (index - 1 + buttons.length) % buttons.length;
        else if (event.key === "Home") next = 0;
        else if (event.key === "End") next = buttons.length - 1;
        else return;
        event.preventDefault();
        buttons[next].focus();
        select(buttons[next]);
      };
    });
    select(buttons[0]);
  });
}

export function simpleReadingFeedback(attempt) {
  const display = attempt.display_feedback || {},
    result = attempt.result || {};
  const dimensions = list(display.dimensions),
    tips = list(display.next_steps)
      .filter((item) => typeof item === "string")
      .slice(0, 2);
  const labels = [
    ["word_match", "Words read"],
    ["pace", "Reading pace"],
    ["pauses", "Pauses"],
    ["pitch", "Voice expression"],
  ];
  const cards = labels
    .map(([key, label]) => {
      const dimension = dimensions.find((item) => item.key === key),
        value =
          dimension?.value_text ||
          {
            word_match: "Waiting for feedback",
            pace: "No comparison yet",
            pauses: "No pause feedback yet",
            pitch: "Not measured yet",
          }[key];
      return `<article class="feedback-dimension"><div class="dimension-label">${label}</div><strong>${escape(value)}</strong><p>${escape(dimension?.detail || "Try a clear recording and check back for feedback.")}</p>${dimension?.status === "observed" ? '<span class="evidence-chip">Observation · not a grade</span>' : dimension?.status === "needs_review" ? '<span class="evidence-chip">Teacher review needed</span>' : ""}</article>`;
    })
    .join("");
  const wordPractice = list(display.word_practice).slice(0, 12);
  return `${tips.length ? `<div class="next-step-box"><span class="eyebrow">Your next small step</span>${tips.map((tip) => `<p>${escape(tip)}</p>`).join("")}</div>` : ""}<div class="feedback-dimensions">${cards}</div>${wordPractice.length ? `<section class="word-practice"><h3>A few words to revisit</h3><div class="word-chip-list">${wordPractice.map((item) => `<span class="word-chip"><strong>${escape(item.word)}</strong><small>${escape(item.reason || "Worth another listen")}</small></span>`).join("")}</div><p class="micro-copy">The recording may not have been heard clearly. These are words to check together, not confirmed pronunciation mistakes.</p></section>` : ""}<p class="feedback-footnote">Pronunciation is not separately graded. Voice expression describes pitch movement; it does not identify feelings.</p>`;
}
