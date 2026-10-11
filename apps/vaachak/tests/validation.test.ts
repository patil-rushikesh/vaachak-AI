import { it, expect } from "vitest";
import { validateItem } from "../src/api/validateItem";
it("requires a usable fill blank", () =>
  expect(
    validateItem({
      kind: "fill",
      prompt: "Good morning",
      options: ["a", "b"],
      correct: 0,
    }),
  ).toContain("underscores"));
it("rejects duplicate answer options", () =>
  expect(
    validateItem({
      kind: "choice",
      prompt: "Pick one",
      options: ["yes", "Yes"],
      correct: 0,
    }),
  ).toContain("different"));
it("rejects out-of-range answer keys", () =>
  expect(
    validateItem({
      kind: "listen",
      text: "Hello",
      options: ["Hello", "Bye"],
      correct: 2,
    }),
  ).toContain("correct answer"));
it("accepts each valid task kind", () => {
  for (const item of [
    { kind: "read", text: "Hello" },
    { kind: "free", prompt: "Introduce yourself" },
    { kind: "build", words: ["Hello", "world"], answer: "Hello world" },
    { kind: "choice", prompt: "Pick one", options: ["a", "b"], correct: 0 },
    {
      kind: "fill",
      prompt: "Good ___",
      options: ["morning", "night"],
      correct: 0,
    },
    { kind: "listen", text: "Hello", options: ["Hello", "Bye"], correct: 0 },
  ] as const)
    expect(validateItem(item as any)).toBeNull();
});
