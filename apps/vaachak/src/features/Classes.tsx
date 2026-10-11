import React, { useState } from "react";
import { View } from "react-native";
import { useQueryClient } from "@tanstack/react-query";
import { useAuth } from "../providers/Auth";
import { get, send } from "../api/client";
import { useData, CourseCard } from "./Learning";
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
export function Classes({ navigation: n }: any) {
  const teacher = useAuth().user?.role === "teacher";
  const q = useData("/classes");
  const [value, setValue] = useState(""),
    [error, setError] = useState<any>(),
    [busy, setBusy] = useState(false);
  return (
    <Page>
      <Pill text={teacher ? "GROW TOGETHER" : "YOUR LEARNING CIRCLE"} />
      <Title>
        {teacher
          ? "A little guidance. A big difference."
          : "You’re in good company."}
      </Title>
      <Card>
        <Title small>{teacher ? "Start a class" : "Join your class"}</Title>
        <Field
          label={teacher ? "Class name" : "Class code"}
          value={value}
          onChangeText={setValue}
          placeholder={
            teacher
              ? "Everyday English · Batch A"
              : "Ask your instructor for the code"
          }
        />
        <ErrorBox error={error} />
        <Button
          title={teacher ? "Create class" : "Join class"}
          busy={busy}
          disabled={!value.trim()}
          onPress={async () => {
            setBusy(true);
            setError(null);
            try {
              const c = await send(
                teacher ? "/classes" : "/classes/join",
                teacher
                  ? { name: value, standard: "adult" }
                  : { code: value.trim() },
              );
              setValue("");
              q.refetch();
              n.navigate("Class", { id: c.id });
            } catch (e) {
              setError(e);
            } finally {
              setBusy(false);
            }
          }}
        />
      </Card>
      <QueryState query={q}>
        {(classes) =>
          classes.length ? (
            classes.map((cl: any) => (
              <Card
                key={cl.id}
                onPress={() => n.navigate("Class", { id: cl.id })}
              >
                <Pill text={`${cl.students} learners`} />
                <Title small>{cl.name}</Title>
                <Label muted>{cl.teacher}</Label>
              </Card>
            ))
          ) : (
            <Empty
              title={
                teacher
                  ? "Your classroom starts here"
                  : "Your class will appear here"
              }
              body={
                teacher
                  ? "Create a class and share its code with your learners."
                  : "Join with a code, or explore independent practice while you wait."
              }
            />
          )
        }
      </QueryState>
    </Page>
  );
}
export function ClassScreen({ route, navigation: n }: any) {
  const id = route.params.id,
    teacher = useAuth().user?.role === "teacher",
    cache = useQueryClient();
  const q = useData(`/classes/${id}`),
    assignments = useData(`/classes/${id}/assignments`),
    courses = useData(`/classes/${id}/courses`);
  const [error, setError] = useState<any>();
  return (
    <Page>
      <QueryState query={q}>
        {(cl) => (
          <>
            <Pill text={teacher ? "YOUR CLASSROOM" : "YOUR LEARNING CIRCLE"} />
            <Title>{cl.name}</Title>
            <Label muted>
              {cl.teacher} · {cl.students} learners
            </Label>
            {teacher && (
              <>
                <Card>
                  <Label muted>
                    Share this joining code with your learners
                  </Label>
                  <Title>{cl.code}</Title>
                  <Confirm
                    title="Refresh joining code"
                    body="The previous code will stop working. Existing learners will remain in this class."
                    onConfirm={async () => {
                      await send(`/classes/${id}/code`);
                      q.refetch();
                    }}
                  />
                </Card>
                <Row>
                  <Button
                    title="Create assignment"
                    onPress={() => n.navigate("Composer", { classId: id })}
                  />
                  <Button
                    title="Learner insights"
                    kind="secondary"
                    onPress={() => n.navigate("Insights", { id })}
                  />
                  <Button
                    title="Assign a course"
                    kind="secondary"
                    onPress={() => n.navigate("Library", { classId: id })}
                  />
                </Row>
              </>
            )}
            <Title small>Class practice</Title>
            <QueryState query={assignments}>
              {(list) =>
                list.length ? (
                  list.map((a: any) => (
                    <Card key={a.id}>
                      <Row style={{ justifyContent: "space-between" }}>
                        <Title small>{a.title}</Title>
                        {a.targeted && <Pill text="Personal follow-up" />}
                      </Row>
                      <Label muted>
                        {a.item_count} tasks
                        {a.due_at
                          ? ` · Due ${new Date(a.due_at).toLocaleDateString()}`
                          : ""}
                      </Label>
                      <Label muted>
                        {teacher
                          ? `${a.completed || 0} learners completed`
                          : `${a.done_items || 0} tasks completed`}
                      </Label>
                      <Button
                        title={teacher ? "View & manage" : "Start practice"}
                        onPress={() =>
                          n.navigate(
                            teacher ? "Assignment" : "Player",
                            teacher
                              ? { id: a.id, classId: id }
                              : {
                                  path: `/assignments/${a.id}`,
                                  source: { assignment_id: a.id },
                                },
                          )
                        }
                      />
                    </Card>
                  ))
                ) : (
                  <Empty
                    title="A little space for something new"
                    body="Your class assignments will appear here."
                  />
                )
              }
            </QueryState>
            <Title small>Class courses</Title>
            <QueryState query={courses}>
              {(data) =>
                (Array.isArray(data) ? data : data.courses || []).map(
                  (course: any) => (
                    <View key={course.id} style={{ gap: 8 }}>
                      <CourseCard course={course} navigation={n} />
                      {teacher && (
                        <Confirm
                          title="Unassign course"
                          body="Learners will lose class access to this course; their evidence is retained."
                          onConfirm={async () => {
                            await send(
                              `/classes/${id}/courses/${course.id}`,
                              undefined,
                              "DELETE",
                            );
                            cache.invalidateQueries();
                          }}
                        />
                      )}
                    </View>
                  ),
                )
              }
            </QueryState>
            {teacher && (
              <>
                <Title small>Learners</Title>
                {cl.roster?.map((student: any) => (
                  <Card key={student.id}>
                    <Label style={{ fontWeight: "700" }}>{student.name}</Label>
                    <Label muted>{student.email}</Label>
                    <Button
                      title="View learning evidence"
                      kind="secondary"
                      onPress={() =>
                        n.navigate("Student", { classId: id, id: student.id })
                      }
                    />
                    <Confirm
                      title="Remove from class"
                      body={`Remove ${student.name} from this class? They will lose access to class work.`}
                      danger
                      onConfirm={async () => {
                        await send(
                          `/classes/${id}/students/${student.id}`,
                          undefined,
                          "DELETE",
                        );
                        cache.invalidateQueries();
                      }}
                    />
                  </Card>
                ))}
                <Confirm
                  title="Archive class"
                  body="This class and its work will disappear from active lists. Evidence is preserved. Restore is currently an operator action."
                  onConfirm={async () => {
                    await send(
                      `/classes/${id}/archive`,
                      { archived: true },
                      "PATCH",
                    );
                    cache.invalidateQueries();
                    n.goBack();
                  }}
                />
              </>
            )}
          </>
        )}
      </QueryState>
      <ErrorBox error={error} />
    </Page>
  );
}
export function TeacherToday({ navigation: n }: any) {
  const q = useData("/classes");
  return (
    <Page>
      <Pill text="A LITTLE GUIDANCE GOES A LONG WAY" />
      <Title>Help someone find their voice.</Title>
      <Label muted>
        Open a class to see the evidence behind each learner’s next step.
      </Label>
      <QueryState query={q}>
        {(data) =>
          data.length ? (
            data.map((cl: any) => (
              <ClassAttention key={cl.id} cl={cl} navigation={n} />
            ))
          ) : (
            <Empty
              title="Let’s bring your class together"
              body="Create a learning space, invite your students, and give them a useful first task."
              action={
                <Button
                  title="Create my first class"
                  onPress={() => n.navigate("Classes")}
                />
              }
            />
          )
        }
      </QueryState>
    </Page>
  );
}
function ClassAttention({ cl, navigation: n }: any) {
  const q = useData(`/classes/${cl.id}/attention`);
  return (
    <Card>
      <Title small>{cl.name}</Title>
      <QueryState query={q}>
        {(data) => (
          <>
            <Label muted>
              {data.rows.length
                ? `${data.rows.length} opportunities to offer support`
                : "No attention flags right now. Check in with learners as usual."}
            </Label>
            {data.rows.slice(0, 3).map((r: any, i: number) => (
              <View key={i} style={{ gap: 6 }}>
                <Label style={{ fontWeight: "700" }}>{r.name}</Label>
                <Label muted>{r.why}</Label>
              </View>
            ))}
          </>
        )}
      </QueryState>
      <Button
        title="Open class insights"
        kind="secondary"
        onPress={() => n.navigate("Insights", { id: cl.id })}
      />
    </Card>
  );
}
export function Insights({ route, navigation: n }: any) {
  const id = route.params.id,
    q = useData(`/classes/${id}/attention`),
    performance = useData(`/classes/${id}/performance`),
    grid = useData(`/classes/${id}/skill-grid`),
    actions = useData(`/classes/${id}/attention/actions`),
    cache = useQueryClient();
  return (
    <Page>
      <Title>Evidence into encouragement.</Title>
      <QueryState query={q}>
        {(data) =>
          data.rows.length ? (
            data.rows.map((r: any, i: number) => (
              <Card key={i}>
                <Title small>{r.name}</Title>
                <Label>{r.why}</Label>
                <Row>
                  <Button
                    title="See evidence"
                    kind="secondary"
                    onPress={() =>
                      n.navigate("Student", { classId: id, id: r.student_id })
                    }
                  />
                  <Button
                    title="Set a follow-up"
                    onPress={() =>
                      n.navigate("Composer", {
                        classId: id,
                        studentId: r.student_id,
                        reason: r.reason,
                        topic: r.detail?.label || "",
                      })
                    }
                  />
                </Row>
                <Row>
                  <Confirm
                    title="Snooze for a day"
                    body="Hide this flag for 24 hours, then check again."
                    onConfirm={async () => {
                      await send(`/classes/${id}/attention/actions`, {
                        student_id: r.student_id,
                        reason: r.reason,
                        status: "snoozed",
                        snooze_until: new Date(
                          Date.now() + 86400000,
                        ).toISOString(),
                      });
                      cache.invalidateQueries();
                    }}
                  />
                  <Confirm
                    title="Mark resolved"
                    body="Resolve this flag based on your review. New evidence can raise it again."
                    onConfirm={async () => {
                      await send(`/classes/${id}/attention/actions`, {
                        student_id: r.student_id,
                        reason: r.reason,
                        status: "resolved",
                      });
                      cache.invalidateQueries();
                    }}
                  />
                </Row>
              </Card>
            ))
          ) : (
            <Empty
              title="Nothing flagged right now"
              body="These signals support your judgment; they do not diagnose a learner’s ability."
            />
          )
        }
      </QueryState>
      <Title small>Class participation</Title>
      <QueryState query={performance}>
        {(d) =>
          d.students.map((p: any) => (
            <Card
              key={p.id || p.student_id}
              onPress={() =>
                n.navigate("Student", { classId: id, id: p.student_id || p.id })
              }
            >
              <Label style={{ fontWeight: "700" }}>{p.name}</Label>
              <Label muted>
                {p.attempts} attempts ·{" "}
                {p.avg_score == null
                  ? "No score yet"
                  : `${Math.round(p.avg_score)}% average task score`}
              </Label>
            </Card>
          ))
        }
      </QueryState>
      <Title small>Skills to revisit</Title>
      <QueryState query={grid}>
        {(d) =>
          d.skills.length ? (
            <Card>
              {d.skills.map((skill: any, i: number) => (
                <View key={skill.code}>
                  <Label style={{ fontWeight: "700" }}>{skill.label}</Label>
                  <Label muted>
                    {d.rows
                      .filter((r: any) => r.counts[i] > 0)
                      .map((r: any) => `${r.name}: ${r.counts[i]}`)
                      .join(" · ")}
                  </Label>
                </View>
              ))}
            </Card>
          ) : (
            <Label muted>No skill-tagged evidence yet.</Label>
          )
        }
      </QueryState>
      <Title small>Follow-up journal</Title>
      <QueryState query={actions}>
        {(d) =>
          d.items.map((a: any, i: number) => (
            <Card key={i}>
              <Pill text={a.status} />
              <Label muted>
                {a.reason.replaceAll("_", " ")} ·{" "}
                {a.follow_up_attempts?.length || 0} follow-up attempts
              </Label>
              <Button
                title="Open learner"
                kind="quiet"
                onPress={() =>
                  n.navigate("Student", { classId: id, id: a.student_id })
                }
              />
            </Card>
          ))
        }
      </QueryState>
    </Page>
  );
}
export function Student({ route, navigation: n }: any) {
  const { id, classId } = route.params,
    q = useData(`/classes/${classId}/students/${id}`);
  return (
    <Page>
      <QueryState query={q}>
        {(d) => (
          <>
            <Title>{d.student.name}</Title>
            <Label muted>
              {d.stats.attempts} attempts ·{" "}
              {d.stats.avg_score == null
                ? "No task scores yet"
                : `${Math.round(d.stats.avg_score)}% average task score`}
            </Label>
            <Button
              title="Set personal follow-up"
              onPress={() => n.navigate("Composer", { classId, studentId: id })}
            />
            <Title small>Recent evidence</Title>
            {d.recent.map((a: any) => (
              <Card
                key={a.id}
                onPress={() => n.navigate("Attempt", { id: a.id })}
              >
                <Pill text={a.kind} />
                <Label>{a.transcript || a.target}</Label>
                <Label muted>
                  {a.score}% · {a.assignment || a.lesson || "Course practice"}
                </Label>
              </Card>
            ))}
          </>
        )}
      </QueryState>
    </Page>
  );
}
export function Assignment({ route, navigation: n }: any) {
  const { id } = route.params,
    q = useData(`/assignments/${id}`),
    cache = useQueryClient();
  const [title, setTitle] = useState(""),
    [error, setError] = useState<any>(),
    [busy, setBusy] = useState(false);
  return (
    <Page>
      <QueryState query={q}>
        {(d) => (
          <>
            <Title>{d.title}</Title>
            <Label muted>{d.instructions}</Label>
            {d.items.map((item: any, i: number) => (
              <Card key={i}>
                <Pill text={item.kind} />
                <Label>
                  {item.prompt || item.text || item.words?.join(" ")}
                </Label>
                {item.options && (
                  <Label muted>Answer: {item.options[item.correct]}</Label>
                )}
              </Card>
            ))}
            <Field label="New title" value={title} onChangeText={setTitle} />
            <ErrorBox error={error} />
            <Button
              title="Update title"
              disabled={!title.trim()}
              busy={busy}
              onPress={async () => {
                setBusy(true);
                try {
                  await send(`/assignments/${id}`, { title }, "PATCH");
                  cache.invalidateQueries();
                  setTitle("");
                } catch (e) {
                  setError(e);
                } finally {
                  setBusy(false);
                }
              }}
            />
            <Confirm
              title="Archive assignment"
              body="Hide this assignment while preserving learner evidence. Restore is currently an operator action."
              onConfirm={async () => {
                await send(
                  `/assignments/${id}/archive`,
                  { archived: true },
                  "PATCH",
                );
                cache.invalidateQueries();
                n.goBack();
              }}
            />
            <Confirm
              title="Delete unused assignment"
              body="Deletion is allowed only when no learner attempts exist. Otherwise, archive it."
              danger
              onConfirm={async () => {
                await send(`/assignments/${id}`, undefined, "DELETE");
                cache.invalidateQueries();
                n.goBack();
              }}
            />
          </>
        )}
      </QueryState>
    </Page>
  );
}
