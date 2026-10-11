import * as Crypto from "expo-crypto";
import { send } from "./client";
// Server discards events unless the learner opted in. No free-form payloads.
export function event(
  name:
    | "onboarding_completed"
    | "practice_started"
    | "feedback_viewed"
    | "retry_completed"
    | "review_completed",
) {
  void send("/events", { id: Crypto.randomUUID(), name }).catch(() => {});
}
