import { event } from "../api/events";
import { Downloads } from "./Downloads";
import { setReminder, stopReminder } from "./reminders";
import React, { useState } from "react";
import { Switch } from "react-native";
import * as Crypto from "expo-crypto";
import { useQueryClient } from "@tanstack/react-query";
import { get, send } from "../api/client";
import { useAuth } from "../providers/Auth";
import { useData } from "./Learning";
import {
  Button,
  Card,
  Field,
  Label,
  Page,
  Title,
  ErrorBox,
  QueryState,
  Row,
  Pill,
} from "../components/ui";
const goals = {
  everyday: "Everyday English",
  interview: "Interview confidence",
  workplace: "Workplace conversations",
  presentation: "Project presentations",
};
export function Growth({ navigation: n }: any) {
  const { user } = useAuth();
  const teacher = user?.role === "teacher";
  const q = useData(teacher ? "/teacher/drafts" : "/me/learning-profile");
  const sessions = useData(
    teacher ? "/teacher/archives" : "/me/practice-sessions",
  );
  const [reminderHour, setReminderHour] = useState("18");
  const [error, setError] = useState<unknown>(),
    [busy, setBusy] = useState(false),
    [message, setMessage] = useState(""),
    [notice, setNotice] = useState("");
  const [conversation, setConversation] = useState<any>(),
    [answer, setAnswer] = useState("");
  const cache = useQueryClient();
  async function act(fn: () => Promise<void>) {
    setBusy(true);
    setError(null);
    try {
      await fn();
    } catch (e) {
      setError(e);
    } finally {
      setBusy(false);
    }
  }
  async function start(mode = "mixed") {
    await act(async () => {
      const s = await send("/me/practice-sessions", {
        client_uuid: Crypto.randomUUID(),
        mode,
        count: 5,
      });
      event("practice_started");
      await cache.invalidateQueries();
      n.navigate("Player", { path: `/me/practice-sessions/${s.id}` });
    });
  }
  return (
    <Page>
      {!teacher && (
        <>
          <Downloads />
          <Card>
            <Title small>A gentle reminder, only if you want it</Title>
            <Field
              label="Reminder hour (07–21, device local time)"
              value={reminderHour}
              onChangeText={setReminderHour}
            />
            <Button
              title="Enable daily reminder"
              kind="secondary"
              disabled={busy}
              onPress={() =>
                act(async () => {
                  await setReminder(Number(reminderHour));
                  setNotice(
                    `Reminder set for ${reminderHour}:00 on this device.`,
                  );
                })
              }
            />
            <Button
              title="Pause reminders"
              kind="quiet"
              disabled={busy}
              onPress={() =>
                act(async () => {
                  await stopReminder();
                  setNotice("Practice reminders are off.");
                })
              }
            />
          </Card>
        </>
      )}

      <Pill text={teacher ? "YOUR STUDIO" : "YOUR NEXT CHAPTER"} />
      <Title>{teacher ? "Saved work" : "Make English your own."}</Title>
      <Label muted>
        {teacher
          ? "Return to a saved draft or restore archived teaching content."
          : "Choose a goal. Start small. Keep learning for as long as you like."}
      </Label>
      <ErrorBox error={error} />
      {notice ? <Label>{notice}</Label> : null}
      <QueryState query={q}>
        {(data) =>
          teacher ? (
            <>
              {!data.length && (
                <Label muted>
                  No saved drafts yet. Save one from the lesson editor.
                </Label>
              )}
              {data.map((d: any) => (
                <Card key={d.id}>
                  <Title small>{d.payload.title || "Untitled draft"}</Title>
                  <Label muted>
                    Saved {new Date(d.updated_at).toLocaleString()}
                  </Label>
                  <Button
                    title="Resume draft"
                    onPress={() =>
                      n.navigate("Composer", { ...d.payload.context, draft: d })
                    }
                  />
                </Card>
              ))}
            </>
          ) : (
            <>
              <Card>
                <Title small>
                  {data.configured
                    ? "Your learning preferences"
                    : "Start with something that matters to you"}
                </Title>
                {Object.entries(goals).map(([key, label]) => (
                  <Button
                    key={key}
                    title={(data.goal === key ? "✓ " : "") + label}
                    kind="secondary"
                    disabled={busy}
                    onPress={() =>
                      act(async () => {
                        await send(
                          "/me/learning-profile",
                          { ...data, goal: key },
                          "PUT",
                        );
                        await q.refetch();
                      })
                    }
                  />
                ))}
                <Row>
                  {["starter", "stretch"].map((d) => (
                    <Button
                      key={d}
                      title={
                        (data.difficulty === d ? "✓ " : "") +
                        (d === "starter"
                          ? "Build foundations"
                          : "Stretch myself")
                      }
                      kind="quiet"
                      disabled={busy}
                      onPress={() =>
                        act(async () => {
                          await send(
                            "/me/learning-profile",
                            { ...data, difficulty: d },
                            "PUT",
                          );
                          await q.refetch();
                        })
                      }
                    />
                  ))}
                </Row>
                <Label>
                  Optional weekly goal: {data.weekly_goal} days. Missing a day
                  never blocks practice.
                </Label>
                <Row>
                  {[2, 3, 5, 7].map((days) => (
                    <Button
                      key={days}
                      title={`${days} days`}
                      kind="quiet"
                      disabled={busy}
                      onPress={() =>
                        act(async () => {
                          await send(
                            "/me/learning-profile",
                            { ...data, weekly_goal: days },
                            "PUT",
                          );
                          await q.refetch();
                        })
                      }
                    />
                  ))}
                </Row>
                <Row>
                  <Switch
                    accessibilityLabel="Share optional usage events"
                    value={data.analytics}
                    onValueChange={(v) =>
                      act(async () => {
                        await send(
                          "/me/learning-profile",
                          { ...data, analytics: v },
                          "PUT",
                        );
                        await q.refetch();
                      })
                    }
                  />
                  <Label>Optional usage analytics (no answers or audio)</Label>
                </Row>
              </Card>
              <Card>
                <Title small>One useful step, then another.</Title>
                <Label muted>
                  Small batches, spaced revision and new situations. When you
                  have seen the available material, we label revision honestly.
                  AI and speech can have service limits.
                </Label>
                <Button
                  title="Start my next practice"
                  disabled={busy}
                  onPress={() => start()}
                />
                <Button
                  title="Try a starting check"
                  kind="secondary"
                  disabled={busy}
                  onPress={() => start("assessment")}
                />
                <Button
                  title="Practise due revision"
                  kind="quiet"
                  disabled={busy}
                  onPress={() => start("review")}
                />
              </Card>
              <Card>
                <Title small>Guided conversation</Title>
                <Label muted>
                  Rehearse four real-life turns at your own pace. These are
                  guided prompts, not a live person or a proficiency test.
                </Label>
                {!conversation ? (
                  <Button
                    title="Start a guided conversation"
                    disabled={busy}
                    onPress={() =>
                      act(async () => {
                        setConversation(
                          await send("/conversations", {
                            id: Crypto.randomUUID(),
                            scenario: data.goal,
                          }),
                        );
                      })
                    }
                  />
                ) : (
                  <>
                    {conversation.turns.map((t: any) => (
                      <Card key={t.id}>
                        <Label muted>{t.prompt}</Label>
                        <Label>{t.text}</Label>
                      </Card>
                    ))}
                    {conversation.complete ? (
                      <>
                        <Label>{conversation.summary}</Label>
                        <Button
                          title="Try another conversation"
                          onPress={() => setConversation(null)}
                        />
                      </>
                    ) : (
                      <>
                        <Title small>{conversation.prompt}</Title>
                        <Field
                          label="Your conversation reply"
                          disabled={busy}
                          value={answer}
                          onChangeText={setAnswer}
                          multiline
                        />
                        <Button
                          title="Continue conversation"
                          disabled={busy || !answer.trim()}
                          onPress={() =>
                            act(async () => {
                              const state = await send(
                                `/conversations/${conversation.id}/turns`,
                                {
                                  id: Crypto.randomUUID(),
                                  revision: conversation.revision,
                                  text: answer,
                                },
                              );
                              setConversation(state);
                              setAnswer("");
                            })
                          }
                        />
                        <Button
                          title="Reload conversation status"
                          kind="quiet"
                          disabled={busy}
                          onPress={() =>
                            act(async () => {
                              setConversation(
                                await get(`/conversations/${conversation.id}`),
                              );
                            })
                          }
                        />
                      </>
                    )}
                  </>
                )}
              </Card>
            </>
          )
        }
      </QueryState>
      <QueryState query={sessions}>
        {(data) =>
          teacher ? (
            <Card>
              <Title small>Archived content</Title>
              {!data.items.length && <Label muted>No archived content.</Label>}
              {data.items.map((a: any) => (
                <Row key={`${a.kind}${a.id}`}>
                  <Label>{a.title}</Label>
                  <Button
                    title={`Restore ${a.title}`}
                    kind="secondary"
                    disabled={busy}
                    onPress={() =>
                      act(async () => {
                        await send(
                          `/${a.kind}/${a.id}/archive`,
                          { archived: false },
                          "PATCH",
                        );
                        await sessions.refetch();
                      })
                    }
                  />
                </Row>
              ))}
            </Card>
          ) : (
            <Card>
              <Title small>Pick up where you left off</Title>
              {!data.length && (
                <Label muted>
                  Your next chapter is ready whenever you are.
                </Label>
              )}
              {data.map((s: any) => (
                <Button
                  key={s.id}
                  title={`Resume ${s.title} · ${s.position}/${s.items.length}`}
                  kind="secondary"
                  onPress={() =>
                    n.navigate("Player", {
                      path: `/me/practice-sessions/${s.id}`,
                    })
                  }
                />
              ))}
            </Card>
          )
        }
      </QueryState>
      <Card>
        <Title small>Help make your next visit better</Title>
        <Field
          label="Your feedback"
          value={message}
          onChangeText={setMessage}
          multiline
        />
        <Label muted>
          Please avoid sharing passwords, contact details or private recordings
          here.
        </Label>
        <Button
          title="Send product feedback"
          disabled={busy || !message.trim()}
          onPress={() =>
            act(async () => {
              const r = await send("/feedback-reports", {
                category: "suggestion",
                message,
              });
              setMessage("");
              setNotice(r.message);
            })
          }
        />
      </Card>
    </Page>
  );
}
