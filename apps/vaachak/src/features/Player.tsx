import { initialTaskIndex } from "./sessionPosition";
import { attemptScoreLabel, isScoredAttempt } from "./attemptScore";
import { FeedbackRating } from "../components/FeedbackRating";
import { event } from "../api/events";
import React, { useEffect, useRef, useState } from "react";
import { Pressable, View } from "react-native";
import * as Speech from "expo-speech";
import * as Crypto from "expo-crypto";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { get, request, send, ApiError } from "../api/client";
import { Attempt, Item, Source } from "../api/types";
import { useRecorder } from "./useRecorder";
import { savePending, clearPending } from "../api/pending";
import { useAuth } from "../providers/Auth";
import { Audio } from "../components/Audio";
import {
  Button,
  Card,
  Empty,
  ErrorBox,
  Field,
  Label,
  Page,
  Pill,
  ProgressBar,
  QueryState,
  Row,
  Title,
} from "../components/ui";
import { colors as c } from "../theme";
export function Player({ route, navigation: n }: any) {
  const p = route.params;
  const q = useQuery({
    queryKey: [p.path || "session", p.items],
    queryFn: () =>
      p.path
        ? get(p.path)
        : Promise.resolve({ title: p.title, items: p.items }),
  });
  return (
    <Page>
      <QueryState query={q}>
        {(data) => (
          <Session
            key={p.path || JSON.stringify(p.items)}
            data={data}
            source={p.source}
            navigation={n}
          />
        )}
      </QueryState>
    </Page>
  );
}
function Session({
  data,
  source,
  navigation: n,
}: {
  data: any;
  source?: Source;
  navigation: any;
}) {
  const [index, setIndex] = useState(initialTaskIndex(data)),
    [done, setDone] = useState(!!data.completed),
    [result, setResult] = useState<Attempt | null>(null),
    [retry, setRetry] = useState<number | undefined>();
  const cache = useQueryClient();
  const items: Item[] = data.items || [];
  if (!items.length)
    return (
      <Empty
        title="Nothing to practise yet"
        body={
          data.instructions ||
          data.intro ||
          "Your instructor is still preparing this activity."
        }
        action={
          data.recording_id ? (
            <Audio path={`/recordings/${data.recording_id}/audio`} />
          ) : undefined
        }
      />
    );
  if (done)
    return (
      <Card style={{ alignItems: "center", padding: 40 }}>
        <Pill text="YOU SHOWED UP FOR YOURSELF" />
        <Title>A little more confident.</Title>
        <Label muted>
          You completed {items.length} tasks. Take one useful correction into
          your day.
        </Label>
        <Button title="Keep practising" onPress={() => n.navigate("Growth")} />
        <Button title="Back to my day" onPress={() => n.navigate("Today")} />
        <Button
          title="See my progress"
          kind="secondary"
          onPress={() => n.navigate("Progress")}
        />
      </Card>
    );
  return (
    <>
      <Row style={{ justifyContent: "space-between" }}>
        <Pill text={data.title || "Practice"} />
        <Label muted>
          {index + 1} of {items.length}
        </Label>
      </Row>
      {data.reason && <Label muted>{data.reason}</Label>}
      <ProgressBar
        value={
          ((index + (result && isScoredAttempt(result) ? 1 : 0)) /
            items.length) *
          100
        }
      />
      {index === 0 && (data.intro || data.instructions) && (
        <Label muted>{data.intro || data.instructions}</Label>
      )}
      {data.recording_id && (
        <Audio path={`/recordings/${data.recording_id}/audio`} />
      )}
      <Task
        key={`${index}:${retry || 0}`}
        item={items[index]}
        source={items[index].source || { ...source, item_index: index }}
        retry={retry}
        sessionData={data.id && data.revision ? data : undefined}
        onResult={(r) => {
          setResult(r);
          event(retry ? "retry_completed" : "feedback_viewed");
          cache.invalidateQueries();
        }}
        result={result}
      />
      {result && (
        <>
          <Feedback key={result.id} attempt={result} />
          <Row>
            {isScoredAttempt(result) ? (
              <Button
                title={
                  index === items.length - 1
                    ? "Finish practice"
                    : "Next small step"
                }
                onPress={() => {
                  setResult(null);
                  setRetry(undefined);
                  if (index === items.length - 1) setDone(true);
                  else setIndex(index + 1);
                }}
              />
            ) : (
              <Button
                title="Back to my day"
                kind="secondary"
                onPress={() => n.navigate("Today")}
              />
            )}
            <Button
              title="Try this again"
              kind="secondary"
              onPress={() => {
                setRetry(result.id);
                setResult(null);
              }}
            />
          </Row>
        </>
      )}
    </>
  );
}
function Task({
  item,
  source,
  retry,
  onResult,
  result,
  sessionData,
}: {
  item: Item;
  source: Source;
  retry?: number;
  onResult: (a: Attempt) => void;
  result: Attempt | null;
  sessionData?: any;
}) {
  const [text, setText] = useState(
      sessionData?.draft?.item_index === source.item_index
        ? sessionData.draft.text
        : "",
    ),
    [choice, setChoice] = useState<number | undefined>(
      sessionData?.draft?.item_index === source.item_index
        ? (sessionData.draft.choice ?? undefined)
        : undefined,
    ),
    [selected, setSelected] = useState<number[]>([]),
    [mode, setMode] = useState<"record" | "type">(
      sessionData?.draft?.text ? "type" : "record",
    ),
    [busy, setBusy] = useState(false),
    [error, setError] = useState<any>(),
    [uncertain, setUncertain] = useState(false);
  const [transcription, setTranscription] = useState<any>(null);
  const transcriptionKey = useRef(Crypto.randomUUID());
  const [draftStatus, setDraftStatus] = useState("");
  const sessionRevision = useRef(sessionData?.revision);
  const draftWrite = useRef<Promise<any> | null>(null);
  const recorder = useRecorder();
  const key = useRef(Crypto.randomUUID());
  const pending = useRef<FormData | null>(null);
  const locked = useRef(false);
  const { user } = useAuth();
  const quiz = ["choice", "fill", "listen"].includes(item.kind);
  const health = useQuery({
    queryKey: ["/health"],
    queryFn: () => get("/health"),
  });
  const [words] = useState(
    () =>
      item.words
        ?.map((word, id) => ({ word, id }))
        .sort(() => Math.random() - 0.5) || [],
  );
  useEffect(() => {
    if (recorder.recording && recorder.duration > 60000)
      void recorder.stop().catch(setError);
  }, [recorder.duration, recorder.recording, recorder.stop]);
  useEffect(
    () => () => {
      void Speech.stop();
    },
    [],
  );
  useEffect(() => {
    if (
      !source.practice_session_id ||
      result ||
      uncertain ||
      busy ||
      item.kind === "build" ||
      (!text && choice === undefined)
    )
      return;
    const timer = setTimeout(() => {
      const work = async () => {
        try {
          const current = await get(
            `/me/practice-sessions/${source.practice_session_id}`,
          );
          // Never overwrite work changed in another window.
          if (sessionRevision.current !== current.revision)
            throw new Error(
              "Practice changed elsewhere. Reload before saving this answer.",
            );
          const saved = await send(
            `/me/practice-sessions/${source.practice_session_id}`,
            {
              revision: sessionRevision.current,
              item_index: source.item_index,
              text,
              choice,
            },
            "PATCH",
          );
          sessionRevision.current = saved.revision;
          setDraftStatus(
            "Answer draft saved. Recordings are uploaded when you request transcription.",
          );
        } catch {
          setDraftStatus(
            "Draft could not be saved. Keep this screen open or copy your answer before leaving.",
          );
        }
      };
      const previous = draftWrite.current;
      draftWrite.current = (async () => {
        if (previous) await previous;
        return work();
      })();
    }, 1200);
    return () => clearTimeout(timer);
  }, [
    text,
    choice,
    source.practice_session_id,
    source.item_index,
    result,
    uncertain,
    busy,
    item.kind,
  ]);
  async function reconcile() {
    setBusy(true);
    try {
      const state = await get(`/me/submissions/${key.current}`);
      if (state.status === "completed") {
        const attempt = await get<Attempt>(`/attempts/${state.attempt_id}`);
        await clearPending(user!.id, key.current).catch(() => {});
        onResult(attempt);
        setUncertain(false);
        return;
      }
      if (state.status === "failed" || state.status === "interrupted") {
        await clearPending(user!.id, key.current);
        setUncertain(false);
        pending.current = null;
        key.current = Crypto.randomUUID();
        throw new Error(
          "That attempt did not finish. Your answer is ready to submit again.",
        );
      }
      throw new Error(
        "Your answer is still being checked. Wait a moment, then check again.",
      );
    } catch (e) {
      if (e instanceof ApiError && e.status === 404) {
        await clearPending(user!.id, key.current).catch(() => {});
        pending.current = null;
        key.current = Crypto.randomUUID();
        setUncertain(false);
        throwAwayError(
          "The server has no saved submission. You can safely submit this answer again.",
        );
      } else setError(e);
    } finally {
      setBusy(false);
    }
  }
  function throwAwayError(message: string) {
    setError(new Error(message));
  }
  async function submit() {
    if (locked.current) return;
    locked.current = true;
    setBusy(true);
    setError(null);
    let attemptStarted = false;
    try {
      if (
        !quiz &&
        item.kind !== "build" &&
        mode === "record" &&
        !transcription
      ) {
        const upload = new FormData();
        upload.append("client_uuid", transcriptionKey.current);
        await recorder.append(upload);
        const t = await request<any>("/transcriptions", {
          method: "POST",
          body: upload,
        });
        if (t.status !== "completed")
          throw new Error(
            "Transcription is not ready. Try again shortly or record again.",
          );
        setTranscription(t);
        setText(t.transcript);
        return;
      }
      if (transcription && mode === "record" && !text.trim())
        throw new Error("Confirm what you said before submitting.");
      const form = pending.current || new FormData();
      if (!pending.current) {
        Object.entries(source).forEach(
          ([k, v]) => v !== undefined && form.append(k, String(v)),
        );
        form.append("client_uuid", key.current);
        if (item.item_version) form.append("item_version", item.item_version);
        if (retry) form.append("retry_of_attempt_id", String(retry));
        if (quiz) form.append("choice", String(choice));
        else if (item.kind === "build")
          form.append(
            "transcript",
            selected.map((i) => words[i].word).join(" "),
          );
        else if (mode === "record") {
          form.append("transcription_id", transcription.id);
          form.append("transcript", text);
        } else form.append("transcript", text);
        pending.current = form;
      }
      await savePending(user!.id, key.current);
      attemptStarted = true;
      const response = await request<Attempt>("/attempts", {
        method: "POST",
        body: form,
      });
      await clearPending(user!.id, key.current).catch(() => {});
      onResult(response);
      setUncertain(false);
    } catch (e) {
      setError(e);
      // Definitive upload rejection is safe to retry with a fresh identity.
      // Retain it for timeouts/5xx because the server may still finish the upload.
      if (
        !attemptStarted &&
        e instanceof ApiError &&
        e.status >= 400 &&
        e.status < 500
      )
        transcriptionKey.current = Crypto.randomUUID();
      if (
        attemptStarted &&
        e instanceof ApiError &&
        (e.status === 0 || e.status >= 500 || e.code.startsWith("submission_"))
      ) {
        setUncertain(true);
      } else {
        await clearPending(user!.id, key.current);
        pending.current = null;
        key.current = Crypto.randomUUID();
      }
    } finally {
      setBusy(false);
      locked.current = false;
    }
  }
  const ready = quiz
    ? choice !== undefined
    : item.kind === "build"
      ? selected.length === words.length
      : mode === "record"
        ? !!recorder.uri
        : !!text.trim();
  return (
    <Card style={{ padding: 28, gap: 22 }}>
      <Pill
        text={
          {
            read: "READ IT ALOUD",
            free: "YOUR TURN TO SPEAK",
            build: "BUILD A SENTENCE",
            choice: "CHOOSE WHAT FITS",
            fill: "FILL THE GAP",
            listen: "LISTEN CLOSELY",
          }[item.kind]
        }
      />
      {item.kind === "listen" ? (
        <>
          <Title small>What did you hear?</Title>
          <Button
            title="Listen to the sentence"
            kind="secondary"
            icon="volume-high"
            onPress={() =>
              Speech.speak(item.text || "", { language: "en", rate: 0.85 })
            }
          />
        </>
      ) : (
        <Title small>
          {item.prompt ||
            item.text ||
            (item.kind === "build"
              ? "Put the words in order"
              : "Your response")}
        </Title>
      )}
      {quiz ? (
        <View style={{ gap: 12 }}>
          {item.options?.map((option, i) => (
            <Pressable
              key={i}
              accessibilityRole="radio"
              accessibilityState={{
                checked: choice === i,
                disabled: !!result || busy || uncertain,
              }}
              disabled={!!result || busy || uncertain}
              onPress={() => setChoice(i)}
              style={{
                padding: 20,
                borderRadius: 16,
                borderWidth: 2,
                borderColor: choice === i ? c.green : c.line,
                backgroundColor: choice === i ? c.soft : c.paper,
              }}
            >
              <Label style={{ fontWeight: "600" }}>
                {String.fromCharCode(65 + i)}　{option}
              </Label>
            </Pressable>
          ))}
        </View>
      ) : item.kind === "build" ? (
        <>
          <Card style={{ backgroundColor: c.soft, minHeight: 90 }}>
            <Row>
              {selected.map((wordIndex, i) => (
                <Button
                  key={i}
                  title={words[wordIndex].word}
                  kind="secondary"
                  disabled={!!result || busy || uncertain}
                  onPress={() =>
                    setSelected(selected.filter((_, j) => i !== j))
                  }
                />
              ))}
            </Row>
            {!selected.length && (
              <Label muted>Tap the words below to build your sentence.</Label>
            )}
          </Card>
          <Row>
            {words.map((entry, i) => (
              <Button
                key={entry.id}
                title={entry.word}
                kind="secondary"
                disabled={selected.includes(i) || !!result || busy || uncertain}
                onPress={() => setSelected([...selected, i])}
              />
            ))}
          </Row>
        </>
      ) : (
        <>
          <Row>
            <Button
              title="Speak"
              kind={mode === "record" ? "primary" : "secondary"}
              disabled={busy || uncertain || !!result || recorder.recording}
              onPress={() => setMode("record")}
            />
            <Button
              title="Type instead"
              kind={mode === "type" ? "primary" : "secondary"}
              disabled={busy || uncertain || !!result || recorder.recording}
              onPress={() => setMode("type")}
            />
          </Row>
          {mode === "type" ? (
            <>
              <Field
                label="Your answer"
                value={text}
                onChangeText={(v) => {
                  if (!busy && !uncertain && !result) setText(v);
                }}
                multiline
              />
              <Label muted>
                Typed practice checks language, not speaking or pronunciation.
              </Label>
            </>
          ) : (
            <>
              <Label muted>
                {health.data?.server_speech_to_text === false
                  ? "Speech recognition is unavailable. Choose “Type instead” to continue."
                  : "Speak naturally. Review what we heard before your answer is evaluated."}
              </Label>
              <Button
                title={
                  recorder.recording
                    ? `Stop recording · ${Math.floor(recorder.duration / 1000)}s`
                    : recorder.uri
                      ? "Record again"
                      : "Tap to record"
                }
                icon={recorder.recording ? "stop" : "mic"}
                kind="secondary"
                disabled={
                  busy ||
                  uncertain ||
                  !!result ||
                  health.data?.server_speech_to_text === false
                }
                onPress={async () => {
                  setError(null);
                  try {
                    if (recorder.recording) await recorder.stop();
                    else {
                      setTranscription(null);
                      transcriptionKey.current = Crypto.randomUUID();
                      await recorder.start();
                    }
                  } catch (e) {
                    setError(e);
                  }
                }}
              />
              {recorder.uri && <Audio uri={recorder.uri} />}
              {transcription && (
                <Card>
                  <Title small>Did we hear you correctly?</Title>
                  <Field
                    label="Confirm your transcript"
                    value={text}
                    onChangeText={(v) => {
                      if (!busy && !uncertain && !result) setText(v);
                    }}
                    multiline
                  />
                  <Label muted>
                    Corrections are labeled as learner-edited text. They do not
                    measure speech recognition or pronunciation.
                  </Label>
                </Card>
              )}
              <Label muted style={{ fontSize: 12 }}>
                Up to 60 seconds. Audio is shared only with you and authorized
                instructors.
              </Label>
            </>
          )}
        </>
      )}
      {draftStatus ? <Label muted>{draftStatus}</Label> : null}
      <ErrorBox error={error} />
      {!result &&
        (uncertain ? (
          <Button
            title="Check submission status"
            busy={busy}
            onPress={reconcile}
          />
        ) : (
          <Button
            title={busy ? "Checking your answer…" : "Check my answer"}
            busy={busy}
            disabled={!ready || recorder.recording}
            onPress={submit}
          />
        ))}
    </Card>
  );
}
export function Feedback({ attempt: a }: { attempt: Attempt }) {
  const [showBasis, setShowBasis] = useState(false);
  const scored = isScoredAttempt(a);
  const teacher = useAuth().user?.role === "teacher";
  const [disputed, setDisputed] = useState(a.disputed),
    [busy, setBusy] = useState(false),
    [error, setError] = useState<any>();
  const cache = useQueryClient();
  return (
    <Card style={{ backgroundColor: c.soft, borderColor: "#C6DDC0" }}>
      <Row style={{ justifyContent: "space-between" }}>
        <Pill
          text={
            !scored
              ? "LET’S CHECK THIS ANSWER"
              : (a.score ?? 0) >= 80
                ? "A LOVELY STEP FORWARD"
                : "HERE’S YOUR NEXT SMALL STEP"
          }
        />
        <Label style={{ fontWeight: "800" }}>{attemptScoreLabel(a)}</Label>
      </Row>
      <Title small>
        {!scored
          ? "This answer has not been scored."
          : a.verdict ||
            ((a.score ?? 0) >= 80
              ? "Nicely done. Keep growing."
              : "You’re learning. Let’s try one change.")}
      </Title>
      {a.transcript && (
        <>
          <Label muted>
            {a.transcript_origin === "server_asr"
              ? "What the system heard"
              : "Your answer"}
          </Label>
          <Label>{a.transcript}</Label>
        </>
      )}
      {scored &&
        a.grammar?.slice(0, 1).map((g, i) => (
          <Card key={i}>
            <Label muted>{g.said}</Label>
            <Label style={{ fontWeight: "700" }}>{g.fix}</Label>
            <Label>{g.why}</Label>
          </Card>
        ))}
      {(scored
        ? a.tips
        : [
            "Check the transcript, record again, or type your answer. This answer does not affect your score or progress.",
          ]
      )
        ?.slice(0, 2)
        .map((tip, i) => (
          <Label key={i}>{tip}</Label>
        ))}
      <Label muted style={{ fontSize: 12 }}>
        {a.source === "ai" ? "AI-assisted feedback" : "Rule-based feedback"} ·{" "}
        {a.input_mode?.replaceAll("_", " ")}. This is task feedback, not an
        accent or proficiency assessment.
      </Label>
      {scored && !!a.next_line && (
        <Card>
          <Label style={{ fontWeight: "700" }}>A little more practice</Label>
          <Label>{a.next_line}</Label>
          <Label muted>
            This suggestion is optional and is not a scored activity.
          </Label>
        </Card>
      )}
      <Button
        title={showBasis ? "Hide feedback details" : "Why this feedback?"}
        kind="quiet"
        onPress={() => setShowBasis(!showBasis)}
      />
      {showBasis && (
        <Card>
          <Title small>How to read this feedback</Title>
          <Label>
            {!scored
              ? "There was not enough reliable evidence to grade this answer. It does not count against your progress."
              : a.basis === "word_accuracy"
                ? "The reading score compares the words in your transcript with the expected sentence. It does not measure your accent."
                : a.basis === "exact_match" ||
                    ["choice", "fill", "listen", "build"].includes(a.kind)
                  ? "This activity checks your answer against the exercise’s expected answer."
                  : "This is coaching for this answer, based on the task rubric. It is not a formal proficiency assessment."}
          </Label>
          {scored && !!a.sources?.length ? (
            <>
              <Label style={{ fontWeight: "700" }}>
                Reviewed notes used by the coach
              </Label>
              {a.sources.map((source, index) => (
                <Card key={`${source.id}-${index}`}>
                  <Label>{source.title}</Label>
                  <Label muted>
                    {source.source}
                    {source.version ? ` · Version ${source.version}` : ""}
                  </Label>
                </Card>
              ))}
              <Label muted>
                These references were checked against the notes supplied to the
                coach for this attempt. A citation does not guarantee that every
                suggestion is correct.
              </Label>
            </>
          ) : (
            <Label muted>
              No teaching-note citations were attached to this attempt.
            </Label>
          )}
        </Card>
      )}
      {!teacher && <FeedbackRating key={a.id} attemptId={a.id} />}
      {a.has_audio && !teacher && (
        <>
          <ErrorBox error={error} />
          <Button
            title={
              disputed
                ? "Restore this evidence"
                : "The transcript isn’t what I said"
            }
            kind="secondary"
            busy={busy}
            onPress={async () => {
              setBusy(true);
              try {
                await send(
                  `/attempts/${a.id}/dispute`,
                  { disputed: !disputed },
                  "PATCH",
                );
                setDisputed(!disputed);
                cache.invalidateQueries();
              } catch (e) {
                setError(e);
              } finally {
                setBusy(false);
              }
            }}
          />
          {disputed && (
            <Label muted>
              This attempt is excluded from skill evidence. You can record
              another try.
            </Label>
          )}
        </>
      )}
    </Card>
  );
}
export function AttemptScreen({ route, navigation: n }: any) {
  const q = useQuery({
    queryKey: [`/attempts/${route.params.id}`],
    queryFn: () => get<Attempt>(`/attempts/${route.params.id}`),
  });
  return (
    <Page>
      <Title>Your practice, revisited.</Title>
      <QueryState query={q}>
        {(a) => (
          <>
            <Feedback attempt={a} />
            {a.has_audio && <Audio path={`/attempts/${a.id}/audio`} />}
            <Card>
              <Title small>The original task</Title>
              <Label>
                {a.item_snapshot?.prompt ||
                  a.item_snapshot?.text ||
                  a.item_snapshot?.words?.join(" ") ||
                  a.kind}
              </Label>
              {a.retry_of_attempt_id && (
                <Button
                  title="Compare the first attempt"
                  kind="secondary"
                  onPress={() =>
                    n.navigate("Attempt", { id: a.retry_of_attempt_id })
                  }
                />
              )}
              {a.retries?.map((id: number) => (
                <Button
                  key={id}
                  title={`See follow-up attempt ${id}`}
                  kind="secondary"
                  onPress={() => n.navigate("Attempt", { id })}
                />
              ))}
            </Card>
          </>
        )}
      </QueryState>
    </Page>
  );
}
