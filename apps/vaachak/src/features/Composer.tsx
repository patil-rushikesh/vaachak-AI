import * as Crypto from "expo-crypto";
import React, { useEffect, useRef, useState } from "react";
import { Switch, View } from "react-native";
import { useQueryClient } from "@tanstack/react-query";
import { get, send, request, ApiError } from "../api/client";
import { Item } from "../api/types";
import { validateItem } from "../api/validateItem";
import skills from "../api/skills.json";
import { useData } from "./Learning";
import { useRecorder } from "./useRecorder";
import { Audio } from "../components/Audio";
import {
  Button,
  Card,
  Confirm,
  Empty,
  ErrorBox,
  Field,
  Label,
  Page,
  Pill,
  QueryState,
  Row,
  Title,
} from "../components/ui";
export function Composer({ route, navigation: n }: any) {
  const p = route.params || {},
    cache = useQueryClient();
  const [title, setTitle] = useState(p.draft?.payload.title || ""),
    [intro, setIntro] = useState(p.draft?.payload.intro || ""),
    [topic, setTopic] = useState(p.draft?.payload.topic || p.topic || ""),
    [items, setItems] = useState<(Item & { reviewed?: boolean })[]>(
      p.draft?.payload.items || [],
    ),
    [due, setDue] = useState(p.draft?.payload.due || ""),
    [recordingId, setRecordingId] = useState<string>(
      p.draft?.payload.recordingId || "",
    ),
    [error, setError] = useState<any>(),
    [busy, setBusy] = useState(false),
    [loading, setLoading] = useState(!!p.lessonId && !p.draft),
    [saveUncertain, setSaveUncertain] = useState(false);
  const draftId = useRef(p.draft?.id || Crypto.randomUUID());
  const draftRevision = useRef(p.draft?.revision || 0);
  const [draftMessage, setDraftMessage] = useState("");
  const recordings = useData("/recordings");
  const [generationJob, setGenerationJob] = useState(
    p.draft?.payload.generationJob || "",
  );
  const draftSaving = useRef(false);
  async function saveDraft() {
    if (draftSaving.current) return;
    draftSaving.current = true;
    setBusy(true);
    setError(null);
    try {
      const { draft, ...context } = p;
      const saved = await send(
        `/teacher/drafts/${draftId.current}`,
        {
          revision: draftRevision.current,
          payload: {
            title,
            intro,
            topic,
            items,
            due,
            recordingId,
            context,
            generationJob,
          },
        },
        "PUT",
      );
      draftRevision.current = saved.revision;
      setDraftMessage("Draft saved. You can return from Saved work.");
      cache.invalidateQueries({ queryKey: ["/teacher/drafts"] });
    } catch (e) {
      setError(e);
    } finally {
      setBusy(false);
      draftSaving.current = false;
    }
  }
  useEffect(() => {
    if (p.lessonId && !p.draft)
      get(`/lessons/${p.lessonId}`)
        .then((d) => {
          setTitle(d.title);
          setIntro(d.intro || "");
          setItems(d.items.map((i: Item) => ({ ...i, reviewed: true })));
          setRecordingId(d.recording_id ? String(d.recording_id) : "");
        })
        .catch(setError)
        .finally(() => setLoading(false));
  }, [p.lessonId, p.draft]);
  useEffect(() => {
    if (loading || saveUncertain || (!title.trim() && !items.length)) return;
    const timer = setTimeout(() => {
      void saveDraft();
    }, 1800);
    return () => clearTimeout(timer);
    // Save the latest editor snapshot after a quiet interval, not on busy/message changes.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [
    title,
    intro,
    topic,
    items,
    due,
    recordingId,
    loading,
    saveUncertain,
    generationJob,
  ]);
  async function save() {
    setBusy(true);
    setError(null);
    try {
      items.forEach((item, index) => {
        const issue = validateItem(item);
        if (issue) throw new Error(`Task ${index + 1}: ${issue}`);
      });
      const clean = items.map(({ reviewed, ...i }) => i);
      let deadline: string | null = null;
      if (due) {
        const date = new Date(due + "T23:59:00");
        if (Number.isNaN(date.getTime()))
          throw new Error("Enter a date in YYYY-MM-DD format.");
        deadline = date.toISOString();
      }
      const payload = {
        title,
        items: clean,
        recording_id: recordingId ? Number(recordingId) : null,
      };
      const saved = await send(
        p.lessonId
          ? `/lessons/${p.lessonId}`
          : p.unitId
            ? `/units/${p.unitId}/lessons`
            : `/classes/${p.classId}/assignments`,
        {
          ...payload,
          ...(p.lessonId || p.unitId
            ? { intro }
            : {
                instructions: intro,
                due_at: deadline,
                student_id: p.studentId || null,
              }),
        },
        p.lessonId ? "PUT" : "POST",
      );
      setSaveUncertain(true);
      if (p.reason && p.studentId) {
        try {
          await send(`/classes/${p.classId}/attention/actions`, {
            student_id: p.studentId,
            reason: p.reason,
            status: "open",
            assignment_id: saved.id,
          });
        } catch {
          throw new Error(
            "Assignment was saved, but linking it to the attention flag failed. Return to the class to view it; do not publish a duplicate.",
          );
        }
      }
      await send(
        `/teacher/drafts/${draftId.current}`,
        undefined,
        "DELETE",
      ).catch(() => {});
      cache.invalidateQueries();
      n.goBack();
    } catch (e) {
      if (e instanceof ApiError && e.status === 0) setSaveUncertain(true);
      setError(e);
    } finally {
      setBusy(false);
    }
  }
  if (loading) return <Page><Label>Loading lesson…</Label></Page>;
  return (
    <Page>
      <Pill
        text={p.studentId ? "PERSONAL FOLLOW-UP" : "TEACH WITH INTENTION"}
      />
      <Title>
        {p.lessonId
          ? "Shape this lesson"
          : p.unitId
            ? "Create a small lesson"
            : "A useful next step."}
      </Title>
      <Label muted>
        Keep it short, clear, and connected to everyday life. Review every task
        before publishing.
      </Label>
      <ErrorBox error={error} />
      <Button
        title="Save draft"
        kind="secondary"
        disabled={busy || saveUncertain}
        onPress={saveDraft}
      />
      <Label muted>
        {draftMessage ||
          "Edits save after a short pause. Check for a saved confirmation before leaving."}
      </Label>
      {saveUncertain && (
        <Card>
          <Label>
            Check your class or course before trying to create this again. It
            may already have been saved.
          </Label>
          <Button
            title="Return and check saved work"
            onPress={() => {
              cache.invalidateQueries();
              n.goBack();
            }}
          />
        </Card>
      )}
      <Field label="Title" value={title} onChangeText={setTitle} />
      <Field
        label={p.classId ? "Instructions" : "Introduction"}
        value={intro}
        onChangeText={setIntro}
        multiline
      />
      {p.classId && (
        <Field
          label="Due date (optional)"
          value={due}
          onChangeText={setDue}
          placeholder="YYYY-MM-DD"
        />
      )}
      <QueryState query={recordings}>
        {(data) =>
          data.length > 0 && (
            <Card>
              <Title small>Reference recording (optional)</Title>
              <Row>
                <Button
                  title="None"
                  kind={!recordingId ? "primary" : "secondary"}
                  onPress={() => setRecordingId("")}
                />
                {data.map((r: any) => (
                  <Button
                    key={r.id}
                    title={r.title}
                    kind={
                      recordingId === String(r.id) ? "primary" : "secondary"
                    }
                    onPress={() => setRecordingId(String(r.id))}
                  />
                ))}
              </Row>
            </Card>
          )
        }
      </QueryState>
      <Card>
        <Title small>A starting point, from AI</Title>
        <Label muted>
          Generate a draft, then edit and approve each item yourself.
        </Label>
        <Field label="Topic" value={topic} onChangeText={setTopic} />
        <Button
          title="Draft three tasks"
          kind="secondary"
          busy={busy}
          disabled={!topic.trim() || items.length > 17}
          onPress={async () => {
            setBusy(true);
            setError(null);
            try {
              const draft = await send("/ai/items", {
                topic,
                count: 3,
                kinds: ["read", "choice", "fill"],
                level: "A1",
              });
              setItems([
                ...items,
                ...draft.items.map((i: Item) => ({ ...i, reviewed: false })),
              ]);
            } catch (e) {
              setError(e);
            } finally {
              setBusy(false);
            }
          }}
        />
      </Card>
      <Card>
        <Title small>Prepare a draft in the background</Title>
        <Label muted>
          Uses the topic above. You can leave after saving this editor draft and
          check the result later. Every generated item still needs your review.
        </Label>
        <Button
          title="Queue AI draft"
          kind="secondary"
          disabled={busy || !topic.trim() || !!generationJob}
          onPress={async () => {
            setBusy(true);
            setError(null);
            try {
              const job = await send("/ai/jobs", {
                client_uuid: Crypto.randomUUID(),
                topic,
                count: 4,
                kinds: ["choice", "read"],
                level: "A1",
              });
              setGenerationJob(job.id);
            } catch (e) {
              setError(e);
            } finally {
              setBusy(false);
            }
          }}
        />
        {!!generationJob && (
          <Button
            title="Check queued draft"
            kind="secondary"
            disabled={busy}
            onPress={async () => {
              setBusy(true);
              setError(null);
              try {
                const job = await get(`/ai/jobs/${generationJob}`);
                if (job.status === "completed") {
                  setItems((old) =>
                    [
                      ...old,
                      ...job.items.map((i: Item) => ({
                        ...i,
                        reviewed: false,
                      })),
                    ].slice(0, 20),
                  );
                  setGenerationJob("");
                } else if (job.status === "failed") {
                  setGenerationJob("");
                  throw new Error(
                    "The provider could not prepare this draft. You can write tasks manually or try later.",
                  );
                } else
                  setDraftMessage(
                    "Draft is still queued or running. Check again shortly.",
                  );
              } catch (e) {
                setError(e);
              } finally {
                setBusy(false);
              }
            }}
          />
        )}
      </Card>
      {items.map((item, i) => (
        <ItemEditor
          key={i}
          item={item}
          index={i}
          change={(v) => setItems(items.map((it, j) => (i === j ? v : it)))}
          remove={() => setItems(items.filter((_, j) => j !== i))}
        />
      ))}
      <Row>
        {(["read", "free", "build", "choice", "fill", "listen"] as const).map(
          (kind) => (
            <Button
              key={kind}
              title={`+ ${kind}`}
              kind="secondary"
              disabled={items.length >= 20}
              onPress={() =>
                setItems([
                  ...items,
                  {
                    kind,
                    ...(["choice", "fill", "listen"].includes(kind)
                      ? { options: ["", ""], correct: 0 }
                      : {}),
                    reviewed: false,
                  },
                ])
              }
            />
          ),
        )}
      </Row>
      <Button
        title={
          p.lessonId
            ? "Save lesson"
            : p.unitId
              ? "Save lesson draft"
              : "Publish assignment"
        }
        busy={busy}
        disabled={
          saveUncertain ||
          loading ||
          !title.trim() ||
          !items.length ||
          items.some((i) => !i.reviewed)
        }
        onPress={save}
      />
      {p.lessonId && (
        <>
          <Confirm
            title="Archive lesson"
            body="Learner evidence will be preserved. Restoring archived content currently needs operator support."
            onConfirm={async () => {
              await send(
                `/lessons/${p.lessonId}/archive`,
                { archived: true },
                "PATCH",
              );
              cache.invalidateQueries();
              n.goBack();
            }}
          />
          <Confirm
            title="Delete unused lesson"
            danger
            body="Only lessons without attempts can be deleted."
            onConfirm={async () => {
              await send(`/lessons/${p.lessonId}`, undefined, "DELETE");
              cache.invalidateQueries();
              n.goBack();
            }}
          />
        </>
      )}
    </Page>
  );
}
function ItemEditor({
  item,
  index,
  change,
  remove,
}: {
  item: Item & { reviewed?: boolean };
  index: number;
  change: (i: any) => void;
  remove: () => void;
}) {
  const quiz = ["choice", "fill", "listen"].includes(item.kind);
  const update = (key: string, value: any) =>
    change({ ...item, [key]: value, reviewed: false });
  return (
    <Card>
      <Row style={{ justifyContent: "space-between" }}>
        <Pill text={`TASK ${index + 1} · ${item.kind}`} />
        <Button title="Remove task" kind="quiet" onPress={remove} />
      </Row>
      {["read", "listen"].includes(item.kind) ? (
        <Field
          label={
            item.kind === "listen"
              ? "Sentence to speak aloud"
              : "Sentence to read"
          }
          value={item.text || ""}
          onChangeText={(v) => update("text", v)}
        />
      ) : item.kind === "build" ? (
        <>
          <Field
            label="Words (separate with |)"
            value={item.words?.join("|") || ""}
            onChangeText={(v) => update("words", v.split("|"))}
          />
          <Field
            label="Correct sentence"
            value={item.answer || ""}
            onChangeText={(v) => update("answer", v)}
          />
        </>
      ) : (
        <Field
          label={
            item.kind === "fill"
              ? "Prompt (include ___ for the blank)"
              : "Prompt"
          }
          value={item.prompt || ""}
          onChangeText={(v) => update("prompt", v)}
        />
      )}
      {quiz && (
        <>
          {item.options?.map((option, i) => (
            <View key={i} style={{ gap: 8 }}>
              <Field
                label={`Option ${i + 1}`}
                value={option}
                onChangeText={(v) =>
                  update(
                    "options",
                    item.options?.map((o, j) => (j === i ? v : o)),
                  )
                }
              />
              <Button
                title={
                  item.correct === i
                    ? "✓ Correct answer"
                    : "Set as correct answer"
                }
                kind={item.correct === i ? "primary" : "secondary"}
                onPress={() => update("correct", i)}
              />
            </View>
          ))}
          <Row>
            <Button
              title="Add option"
              kind="quiet"
              disabled={(item.options?.length || 0) >= 6}
              onPress={() => update("options", [...(item.options || []), ""])}
            />
            <Button
              title="Remove last option"
              kind="quiet"
              disabled={(item.options?.length || 0) <= 2}
              onPress={() =>
                change({
                  ...item,
                  options: item.options?.slice(0, -1),
                  correct: 0,
                  reviewed: false,
                })
              }
            />
          </Row>
          <Field
            label="Explanation"
            value={item.explain || ""}
            onChangeText={(v) => update("explain", v)}
            multiline
          />
        </>
      )}
      <Label>What does this task practise? (optional)</Label>
      <Row>
        {skills.map((skill) => (
          <Button
            key={skill.code}
            title={skill.label}
            kind={
              item.skill_ids?.includes(skill.code) ? "primary" : "secondary"
            }
            onPress={() =>
              update(
                "skill_ids",
                item.skill_ids?.includes(skill.code) ? [] : [skill.code],
              )
            }
          />
        ))}
      </Row>
      <Label muted>
        Choose one reviewed focus to support explainable follow-up.
      </Label>
      <Row>
        <Switch
          accessibilityLabel={`Approve task ${index + 1}`}
          value={!!item.reviewed}
          onValueChange={(v) => change({ ...item, reviewed: v })}
        />
        <Label>I reviewed this task and its answer.</Label>
      </Row>
    </Card>
  );
}
export function Recordings() {
  const q = useData("/recordings"),
    r = useRecorder();
  const [title, setTitle] = useState(""),
    [busy, setBusy] = useState(false),
    [error, setError] = useState<any>();
  useEffect(() => {
    if (r.recording && r.duration > 60000) void r.stop().catch(setError);
  }, [r.duration]);
  return (
    <Page>
      <Title>A familiar voice helps.</Title>
      <Label muted>Record a short reference for assignments and lessons.</Label>
      <Card>
        <Field label="Recording title" value={title} onChangeText={setTitle} />
        <ErrorBox error={error} />
        <Button
          title={
            r.recording
              ? `Stop · ${Math.floor(r.duration / 1000)}s`
              : "Record a voice reference"
          }
          kind="secondary"
          disabled={busy}
          onPress={async () => {
            try {
              if (r.recording) await r.stop();
              else await r.start();
            } catch (e) {
              setError(e);
            }
          }}
        />
        {r.uri && <Audio uri={r.uri} />}
        <Button
          title="Save recording"
          disabled={!r.uri || !title.trim() || r.recording}
          busy={busy}
          onPress={async () => {
            setBusy(true);
            try {
              const form = new FormData();
              form.append("title", title);
              form.append(
                "duration_ms",
                String(Math.max(500, Math.round(r.duration))),
              );
              await r.append(form, "file");
              await request("/recordings", { method: "POST", body: form });
              q.refetch();
              r.clear();
              setTitle("");
            } catch (e) {
              setError(e);
            } finally {
              setBusy(false);
            }
          }}
        />
      </Card>
      <QueryState query={q}>
        {(data) =>
          data.length ? (
            data.map((r: any) => (
              <Card key={r.id}>
                <Title small>{r.title}</Title>
                <Audio path={`/recordings/${r.id}/audio`} />
                <Confirm
                  title="Delete reference recording"
                  danger
                  body="This audio will no longer be available in attached work."
                  onConfirm={async () => {
                    await send(`/recordings/${r.id}`, undefined, "DELETE");
                    q.refetch();
                  }}
                />
              </Card>
            ))
          ) : (
            <Empty
              title="Your voice library starts here"
              body="Save a reference, then attach it when creating a lesson or assignment."
            />
          )
        }
      </QueryState>
    </Page>
  );
}
