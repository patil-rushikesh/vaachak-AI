type Evaluation = { score: number | null; evaluation_status?: string };

export function isScoredAttempt(attempt: Evaluation): boolean {
  return attempt.evaluation_status !== "unscored" && attempt.score != null;
}

export function attemptScoreLabel(attempt: Evaluation): string {
  return isScoredAttempt(attempt)
    ? `${attempt.score}% task score`
    : "Not scored";
}
