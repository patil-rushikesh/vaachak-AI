export type User = {
  id: number;
  name: string;
  email: string;
  role: "teacher" | "student" | "learner";
};
export type Item = {
  kind: "read" | "free" | "build" | "choice" | "fill" | "listen";
  text?: string;
  prompt?: string;
  words?: string[];
  options?: string[];
  answer?: string;
  correct?: number;
  explain?: string;
  skill_ids?: string[];
  item_version?: string;
  source?: Source;
  reason?: string;
  evidence_ids?: number[];
};
export type Source = {
  practice_session_id?: string;
  set_id?: string;
  assignment_id?: number;
  lesson_id?: number;
  item_index?: number;
};
export type Attempt = {
  id: number;
  score: number;
  kind: Item["kind"];
  transcript: string;
  tips: string[];
  source?: string;
  verdict?: string;
  strengths?: string[];
  grammar?: { said: string; fix: string; why: string }[];
  input_mode: string;
  transcript_origin: string;
  disputed: boolean;
  has_audio: boolean;
  item_snapshot: Item;
  retries?: number[];
  created_at?: string;
  retry_of_attempt_id?: number;
};
