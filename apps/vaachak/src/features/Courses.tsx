import React, { useState } from "react";
import { View } from "react-native";
import { useQueryClient } from "@tanstack/react-query";
import { send } from "../api/client";
import { useAuth } from "../providers/Auth";
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
  ProgressBar,
  QueryState,
  Row,
  Title,
} from "../components/ui";
export function Library({ route, navigation: n }: any) {
  const q = useData("/courses"),
    cache = useQueryClient();
  const [title, setTitle] = useState(""),
    [error, setError] = useState<any>(),
    [busy, setBusy] = useState(false);
  const classId = route.params?.classId;
  return (
    <Page>
      <Title>
        {classId
          ? "Choose a course for your class"
          : "A home for your teaching."}
      </Title>
      <Label muted>Build a thoughtful path, one small lesson at a time.</Label>
      {!classId && (
        <>
          <Card>
            <Field
              label="New course title"
              value={title}
              onChangeText={setTitle}
            />
            <ErrorBox error={error} />
            <Button
              title="Create a draft course"
              busy={busy}
              disabled={!title.trim()}
              onPress={async () => {
                setBusy(true);
                try {
                  const course = await send("/courses", {
                    title,
                    level: "A1",
                    visibility: "classes",
                    sequential: true,
                  });
                  cache.invalidateQueries();
                  setTitle("");
                  n.navigate("Course", { id: course.id });
                } catch (e) {
                  setError(e);
                } finally {
                  setBusy(false);
                }
              }}
            />
          </Card>
          <Button
            title="Voice reference library"
            kind="secondary"
            onPress={() => n.navigate("Recordings")}
          />
        </>
      )}
      <QueryState query={q}>
        {(data) =>
          data.mine.length ? (
            data.mine.map((course: any) => (
              <View key={course.id} style={{ gap: 10 }}>
                <CourseCard course={course} navigation={n} />
                {classId && course.status === "published" && (
                  <Confirm
                    title="Assign to this class"
                    body={`Give this class access to ${course.title}?`}
                    onConfirm={async () => {
                      await send(`/classes/${classId}/courses`, {
                        course_id: course.id,
                      });
                      cache.invalidateQueries();
                      n.goBack();
                    }}
                  />
                )}
              </View>
            ))
          ) : (
            <Empty
              title="Make your first learning path"
              body="Add a course, create a unit, and fill it with short lessons."
            />
          )
        }
      </QueryState>
    </Page>
  );
}
export function Course({ route, navigation: n }: any) {
  const id = route.params.id,
    q = useData(`/courses/${id}`),
    cache = useQueryClient();
  const [unit, setUnit] = useState(""),
    [title, setTitle] = useState(""),
    [summary, setSummary] = useState(""),
    [error, setError] = useState<any>(),
    [busy, setBusy] = useState(false);
  async function action(path: string, body?: any, method = "POST") {
    setError(null);
    setBusy(true);
    try {
      await send(path, body, method);
      cache.invalidateQueries();
    } catch (e) {
      setError(e);
    } finally {
      setBusy(false);
    }
  }
  return (
    <Page>
      <QueryState query={q}>
        {(d) => (
          <>
            <Pill
              text={`${d.level} · ${d.mode === "owner" ? d.status : "Learning path"}`}
            />
            <Title>{d.title}</Title>
            <Label muted>{d.summary}</Label>
            <ErrorBox error={error} />
            {d.progress && (
              <>
                <ProgressBar value={d.progress.percent} />
                <Label muted>
                  {d.progress.lessons_done} of {d.progress.lessons_total}{" "}
                  lessons complete
                </Label>
              </>
            )}
            {d.mode !== "owner" && !d.enrolled && (
              <Button
                title="Add to my learning"
                busy={busy}
                onPress={() => action(`/courses/${id}/enroll`)}
              />
            )}
            {d.mode === "owner" && (
              <>
                <Row>
                  <Button
                    title={
                      d.status === "published"
                        ? "Unpublish course"
                        : "Publish course"
                    }
                    busy={busy}
                    onPress={() =>
                      action(`/courses/${id}/publish`, {
                        published: d.status !== "published",
                      })
                    }
                  />
                  <Button
                    title="Course progress"
                    kind="secondary"
                    onPress={() => n.navigate("CourseProgress", { id })}
                  />
                </Row>
                <Card>
                  <Title small>Course details</Title>
                  <Field
                    label="Updated title"
                    value={title}
                    onChangeText={setTitle}
                    placeholder={d.title}
                  />
                  <Field
                    label="Updated summary"
                    value={summary}
                    onChangeText={setSummary}
                    multiline
                    placeholder={
                      d.summary || "What will your learners explore?"
                    }
                  />
                  <Button
                    title="Save details"
                    kind="secondary"
                    busy={busy}
                    disabled={!title.trim() && !summary.trim()}
                    onPress={() =>
                      action(
                        `/courses/${id}`,
                        {
                          ...(title.trim() ? { title } : {}),
                          ...(summary.trim() ? { summary } : {}),
                        },
                        "PATCH",
                      )
                    }
                  />
                  <Row>
                    <Button
                      title={
                        d.visibility === "public"
                          ? "Limit to assigned classes"
                          : "Make publicly discoverable"
                      }
                      kind="secondary"
                      busy={busy}
                      onPress={() =>
                        action(
                          `/courses/${id}`,
                          {
                            visibility:
                              d.visibility === "public" ? "classes" : "public",
                          },
                          "PATCH",
                        )
                      }
                    />
                    <Button
                      title={
                        d.sequential
                          ? "Allow any lesson order"
                          : "Require lesson order"
                      }
                      kind="secondary"
                      busy={busy}
                      onPress={() =>
                        action(
                          `/courses/${id}`,
                          { sequential: !d.sequential },
                          "PATCH",
                        )
                      }
                    />
                  </Row>
                </Card>
              </>
            )}
            {d.units.map((u: any, i: number) => (
              <Card key={u.id}>
                <Row style={{ justifyContent: "space-between" }}>
                  <Pill text={`UNIT ${i + 1}`} />
                  <Title small>{u.title}</Title>
                </Row>
                {u.lessons.map((l: any, j: number) => (
                  <View key={l.id} style={{ gap: 10, paddingVertical: 10 }}>
                    <Row>
                      <Pill
                        text={
                          l.status === "locked"
                            ? "Locked"
                            : l.status === "done"
                              ? "Completed"
                              : `${j + 1}`
                        }
                      />
                      <Label style={{ fontWeight: "700", flex: 1 }}>
                        {l.title}
                      </Label>
                      <Label muted>{l.item_count} tasks</Label>
                    </Row>
                    <Button
                      title={
                        d.mode === "owner"
                          ? "Edit lesson"
                          : l.status === "locked"
                            ? "Finish the previous lesson"
                            : l.status === "done"
                              ? "Practise again"
                              : "Start lesson"
                      }
                      kind="secondary"
                      disabled={l.status === "locked"}
                      onPress={() =>
                        n.navigate(
                          d.mode === "owner" ? "Composer" : "Player",
                          d.mode === "owner"
                            ? { lessonId: l.id }
                            : {
                                path: `/lessons/${l.id}`,
                                source: { lesson_id: l.id },
                              },
                        )
                      }
                    />
                    {d.mode === "owner" && (
                      <Row>
                        <Button
                          title="Move up"
                          kind="quiet"
                          disabled={busy || j === 0}
                          onPress={() =>
                            action(`/lessons/${l.id}/move`, { direction: "up" })
                          }
                        />
                        <Button
                          title="Move down"
                          kind="quiet"
                          disabled={busy || j === u.lessons.length - 1}
                          onPress={() =>
                            action(`/lessons/${l.id}/move`, {
                              direction: "down",
                            })
                          }
                        />
                      </Row>
                    )}
                  </View>
                ))}
                {d.mode === "owner" && (
                  <>
                    <Button
                      title="Add lesson"
                      onPress={() => n.navigate("Composer", { unitId: u.id })}
                    />
                    <UnitTools
                      unit={u}
                      first={i === 0}
                      last={i === d.units.length - 1}
                      action={action}
                      refresh={() => cache.invalidateQueries()}
                      busy={busy}
                    />
                  </>
                )}
              </Card>
            ))}
            {!d.units.length && (
              <Empty
                title="A path waiting to grow"
                body="Add a unit and a lesson to get started."
              />
            )}
            {d.mode === "owner" ? (
              <>
                <Card>
                  <Field
                    label="New unit title"
                    value={unit}
                    onChangeText={setUnit}
                  />
                  <Button
                    title="Add unit"
                    busy={busy}
                    disabled={!unit.trim()}
                    onPress={async () => {
                      await action(`/courses/${id}/units`, { title: unit });
                      setUnit("");
                    }}
                  />
                </Card>
                <Confirm
                  title="Archive course"
                  body="Hide this course while retaining attempts. Restoring archived content currently needs operator support."
                  onConfirm={async () => {
                    await send(
                      `/courses/${id}/archive`,
                      { archived: true },
                      "PATCH",
                    );
                    cache.invalidateQueries();
                    n.goBack();
                  }}
                />
                <Confirm
                  title="Delete unused course"
                  danger
                  body="Only courses without learner attempts can be deleted. Archive courses with evidence."
                  onConfirm={async () => {
                    await send(`/courses/${id}`, undefined, "DELETE");
                    cache.invalidateQueries();
                    n.goBack();
                  }}
                />
              </>
            ) : (
              d.enrolled &&
              !d.via_class && (
                <Confirm
                  title="Leave course"
                  body="Remove this course from your learning list? Your previous attempts are retained."
                  onConfirm={async () => {
                    await send(`/courses/${id}/enroll`, undefined, "DELETE");
                    cache.invalidateQueries();
                    n.goBack();
                  }}
                />
              )
            )}
          </>
        )}
      </QueryState>
    </Page>
  );
}
function UnitTools({ unit: u, first, last, action, busy, refresh }: any) {
  const [name, setName] = useState("");
  return (
    <>
      <Field
        label="Rename unit"
        value={name}
        onChangeText={setName}
        placeholder={u.title}
      />
      <Row>
        <Button
          title="Rename"
          kind="secondary"
          busy={busy}
          disabled={!name.trim()}
          onPress={() => action(`/units/${u.id}`, { title: name }, "PATCH")}
        />
        <Button
          title="Move unit up"
          kind="quiet"
          disabled={first || busy}
          onPress={() => action(`/units/${u.id}/move`, { direction: "up" })}
        />
        <Button
          title="Move unit down"
          kind="quiet"
          disabled={last || busy}
          onPress={() => action(`/units/${u.id}/move`, { direction: "down" })}
        />
      </Row>
      <Confirm
        title="Delete unused unit"
        danger
        body="This removes the unit and its lessons only if they have no learner attempts."
        onConfirm={async () => {
          await send(`/units/${u.id}`, undefined, "DELETE");
          await refresh();
        }}
      />
    </>
  );
}
export function CourseProgress({ route, navigation: n }: any) {
  const q = useData(`/courses/${route.params.id}/progress`);
  return (
    <Page>
      <Title>How your course is growing.</Title>
      <QueryState query={q}>
        {(d) => (
          <>
            <Title small>Learners</Title>
            {d.learners.map((l: any, i: number) => (
              <Card key={i}>
                <Label style={{ fontWeight: "700" }}>{l.name}</Label>
                <Label muted>
                  {l.lessons_done ?? l.progress?.lessons_done ?? 0} lessons
                  completed · {l.avg ?? l.progress?.avg ?? "—"} average task
                  score
                </Label>
              </Card>
            ))}
            <Title small>Lesson participation</Title>
            {d.lessons.map((l: any, i: number) => (
              <Card key={i}>
                <Label style={{ fontWeight: "700" }}>{l.title}</Label>
                <Label muted>
                  {l.completed ?? l.done ?? 0} completed · {l.started ?? 0}{" "}
                  started
                </Label>
              </Card>
            ))}
          </>
        )}
      </QueryState>
    </Page>
  );
}
