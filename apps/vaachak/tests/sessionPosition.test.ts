import { expect, it } from "vitest";
import { initialTaskIndex } from "../src/features/sessionPosition";
it("starts a course lesson at its first task regardless of lesson ordinal", () => {
  expect(
    initialTaskIndex({ id: 20, position: 3, items: [{ kind: "choice" }] }),
  ).toBe(0);
});
it("resumes an owned personal session at its saved task", () => {
  expect(
    initialTaskIndex({
      id: "session",
      position: 1,
      items: [
        { kind: "choice", source: { practice_session_id: "session" } },
        { kind: "read" },
      ],
    }),
  ).toBe(1);
});
it("handles a stale or invalid task cursor without indexing past the task array", () => {
  for (const position of [-1, 2, 1.5])
    expect(
      initialTaskIndex({
        id: "session",
        position,
        items: [{ kind: "choice", source: { practice_session_id: "session" } }],
      }),
    ).toBe(0);
});
