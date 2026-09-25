import assert from "node:assert/strict";
import test from "node:test";
import { assessedScore, completionChart } from "./insights.js";

const empty = {
  graded: 0,
  pending: 0,
  needs_review: 0,
  not_started: 0,
  total: 0,
};

test("an explicitly empty assignment set is shown as empty, without a zero grade", () => {
  const html = completionChart(empty);
  assert.match(html, /No assigned practices yet/);
  assert.doesNotMatch(html, /not available|0%|NaN|pathLength="100"/);
});

test("mixed practice states form one truthful whole, including unstarted work", () => {
  const html = completionChart({
    graded: 4,
    pending: 2,
    needs_review: 1,
    not_started: 3,
    total: 10,
  });
  assert.match(
    html,
    /4 feedback ready, 2 being checked, 1 needs attention, 3 not started/,
  );
  for (const [count, percent] of [
    [4, 40],
    [2, 20],
    [1, 10],
    [3, 30],
  ])
    assert.ok(html.includes(`${count} · ${percent}%`));
  assert.match(html, /4\/10/);
  assert.equal((html.match(/pathLength="100"/g) || []).length, 4);
});

test("missing, malformed, and inconsistent counts are unavailable, never empty", () => {
  const invalid = [
    undefined,
    null,
    {},
    { total: 0 },
    { ...empty, graded: 1 },
    { ...empty, total: 2 },
    { ...empty, graded: -1, total: -1 },
    { ...empty, graded: 0.5, total: 0.5 },
    { ...empty, pending: NaN },
    { ...empty, total: Infinity },
    { ...empty, graded: "0" },
    { ...empty, needs_review: false },
    { ...empty, total: Number.MAX_SAFE_INTEGER + 1 },
  ];
  for (const status of invalid) {
    const html = completionChart(status);
    assert.match(html, /Practice status is not available/);
    assert.doesNotMatch(
      html,
      /No assigned practices yet|no practices yet|<svg|0%/,
    );
  }
});

test("only finite in-range completed scores are plotted; ungraded does not become zero", () => {
  assert.equal(assessedScore({ status: "completed", score: 0 }), 0);
  assert.equal(assessedScore({ status: "completed", score: 1 }), 1);
  assert.equal(assessedScore({ status: "completed", score: 0.72 }), 0.72);
  for (const score of [
    null,
    undefined,
    NaN,
    Infinity,
    -Infinity,
    -0.01,
    1.01,
    "0",
    false,
  ])
    assert.equal(assessedScore({ status: "completed", score }), null);
  for (const status of ["pending", "needs_review", "failed", undefined])
    for (const score of [0, 0.9, 1])
      assert.equal(assessedScore({ status, score }), null);
  assert.equal(assessedScore(null), null);
});
