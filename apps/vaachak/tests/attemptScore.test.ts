import { expect, test } from "vitest";
import {
  attemptScoreLabel,
  isScoredAttempt,
} from "../src/features/attemptScore";

test("unscored answers never display a percentage, including legacy numeric results", () => {
  for (const score of [null, 0, 35]) {
    const a = { score, evaluation_status: "unscored" };
    expect(isScoredAttempt(a)).toBe(false);
    expect(attemptScoreLabel(a)).toBe("Not scored");
  }
  expect(attemptScoreLabel({ score: null })).toBe("Not scored");
});

test("ordinary numeric results remain scored including genuine zero scores", () => {
  expect(attemptScoreLabel({ score: 0 })).toBe("0% task score");
  expect(attemptScoreLabel({ score: 100, evaluation_status: "scored" })).toBe(
    "100% task score",
  );
});
