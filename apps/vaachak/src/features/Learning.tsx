import { attemptScoreLabel } from "./attemptScore";
import React, { useState } from "react";
import { View, useWindowDimensions } from "react-native";
import { useQuery } from "@tanstack/react-query";
import Ionicons from "@expo/vector-icons/Ionicons";
import { get } from "../api/client";
import { PendingSubmissions } from "../components/PendingSubmissions";
import { useAuth } from "../providers/Auth";
import {
  Button,
  Card,
  Empty,
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
export const useData = (path: string) =>
  useQuery({ queryKey: [path], queryFn: () => get(path) });
export function Today({ navigation: n }: any) {
  const { user } = useAuth();
  const stats = useData("/me/stats"),
    courses = useData("/courses"),
    review = useData("/me/review"),
    recommend = useData("/me/recommendations");
  const wide = useWindowDimensions().width > 850;
  return (
    <Page
      refresh={() => {
        stats.refetch();
        courses.refetch();
        review.refetch();
        recommend.refetch();
      }}
      refreshing={stats.isRefetching}
    >
      <PendingSubmissions navigation={n} />
      <Button
        title="My goals & continuous practice"
        kind="secondary"
        onPress={() => n.navigate("Growth")}
      />
      <Row style={{ justifyContent: "space-between" }}>
        <View style={{ gap: 6 }}>
          <Label muted>MAKE ROOM FOR A LITTLE GROWTH</Label>
          <Title>Hello, {user?.name.split(" ")[0]} ☀</Title>
        </View>
        <Pill
          text={`${stats.data?.streak_days || 0} day practice streak`}
          tone="orange"
        />
      </Row>
      <View style={{ flexDirection: wide ? "row" : "column", gap: 22 }}>
        <View style={{ flex: 2, gap: 22 }}>
          <Card
            style={{
              backgroundColor: c.green,
              borderColor: c.green,
              padding: 30,
              overflow: "hidden",
            }}
          >
            <Pill text="YOUR DAILY MOMENT" />
            <Title>
              <Label
                style={{
                  fontSize: 32,
                  lineHeight: 40,
                  fontWeight: "800",
                  color: "white",
                }}
              >
                A small step today.{"\n"}A stronger voice tomorrow.
              </Label>
            </Title>
            <Label style={{ color: "#DBECDC", maxWidth: 460 }}>
              Make a little time for English. Pick a task, try it out, and
              discover what to practise next.
            </Label>
            <Row>
              <Button
                title={
                  review.data?.items?.length
                    ? "Start your review"
                    : "Find my next practice"
                }
                kind="secondary"
                icon="arrow-forward"
                onPress={() =>
                  n.navigate(review.data?.items?.length ? "Review" : "Practice")
                }
              />
              <Ionicons name="leaf" size={65} color={c.lime} />
            </Row>
          </Card>
          <QueryState query={courses}>
            {(data) =>
              data.mine.length ? (
                <>
                  <Row style={{ justifyContent: "space-between" }}>
                    <Title small>Your learning path</Title>
                    <Button
                      title="See all"
                      kind="quiet"
                      onPress={() => n.navigate("Practice")}
                    />
                  </Row>
                  {data.mine.slice(0, 2).map((course: any) => (
                    <CourseCard
                      key={course.id}
                      course={course}
                      navigation={n}
                    />
                  ))}
                </>
              ) : (
                <Card>
                  <Pill text="START SOMETHING GOOD" />
                  <Title small>Your first small win</Title>
                  <Label muted>
                    Everyday English is a great place to begin. No placement
                    test needed.
                  </Label>
                  <Button
                    title="Explore practice"
                    onPress={() => n.navigate("Practice")}
                  />
                </Card>
              )
            }
          </QueryState>
          <QueryState query={recommend}>
            {(data) =>
              data.items.length > 0 && (
                <Card>
                  <Title small>Picked for your next step</Title>
                  <Label muted>
                    Try a different task to revisit a skill from your practice.
                  </Label>
                  {data.items.slice(0, 2).map((r: any, i: number) => (
                    <Button
                      key={i}
                      title={
                        r.reason === "delayed_check_due"
                          ? "Time for a fresh check"
                          : "Revisit a recent correction"
                      }
                      kind="secondary"
                      onPress={() =>
                        n.navigate("Player", {
                          title: "Your next step",
                          items: [{ ...r.item, source: r.source }],
                        })
                      }
                    />
                  ))}
                </Card>
              )
            }
          </QueryState>
        </View>
        <View style={{ flex: 1, gap: 22 }}>
          <QueryState query={stats}>
            {(data) => (
              <>
                <Card>
                  <Row>
                    <Ionicons
                      name="sparkles-outline"
                      size={25}
                      color={c.green}
                    />
                    <Title small>Your week, growing</Title>
                  </Row>
                  <Row style={{ justifyContent: "space-between" }}>
                    {(data.days || []).slice(-7).map((day: any, i: number) => (
                      <View
                        key={day.day}
                        style={{ gap: 8, alignItems: "center" }}
                      >
                        <View
                          style={{
                            width: 28,
                            height: 36,
                            borderRadius: 12,
                            backgroundColor: day.attempts ? c.green : c.soft,
                            alignItems: "center",
                            justifyContent: "center",
                          }}
                        >
                          {day.attempts > 0 && (
                            <Ionicons
                              name="checkmark"
                              size={18}
                              color="white"
                            />
                          )}
                        </View>
                        <Label muted style={{ fontSize: 11 }}>
                          {
                            ["S", "M", "T", "W", "T", "F", "S"][
                              new Date(`${day.day}T12:00:00`).getDay()
                            ]
                          }
                        </Label>
                      </View>
                    ))}
                  </Row>
                  <Label muted>
                    {data.attempts} practice attempts •{" "}
                    {data.avg_score == null
                      ? "Your story starts here"
                      : `${Math.round(data.avg_score)}% average task score`}
                  </Label>
                </Card>
                <Card
                  style={{ backgroundColor: c.peach, borderColor: "#F3DFC1" }}
                >
                  <Pill text="A GENTLE REMINDER" tone="orange" />
                  <Title small>Progress is personal.</Title>
                  <Label muted>
                    One useful correction is enough for today. These scores
                    describe individual tasks, not your overall English ability.
                  </Label>
                </Card>
              </>
            )}
          </QueryState>
          <Card>
            <Title small>Learning with a class?</Title>
            <Label muted>
              Your instructor’s assignments live in one place.
            </Label>
            <Button
              title="Open my classes"
              kind="secondary"
              onPress={() => n.navigate("Classes")}
            />
          </Card>
        </View>
      </View>
    </Page>
  );
}
export function CourseCard({ course, navigation: n }: any) {
  return (
    <Card onPress={() => n.navigate("Course", { id: course.id })}>
      <Row style={{ justifyContent: "space-between" }}>
        <Pill text={course.level || "English"} />
        <Ionicons name="arrow-forward" size={22} color={c.green} />
      </Row>
      <Title small>{course.title}</Title>
      <Label muted>
        {course.summary ||
          course.teacher ||
          "Build confidence one lesson at a time."}
      </Label>
      {course.progress && (
        <>
          <ProgressBar value={course.progress.percent || 0} />
          <Label muted style={{ fontSize: 13 }}>
            {course.progress.lessons_done} of {course.progress.lessons_total}{" "}
            lessons completed
          </Label>
        </>
      )}
    </Card>
  );
}
export function Practice({ navigation: n }: any) {
  const catalog = useData("/catalog"),
    courses = useData("/courses");
  const [search, setSearch] = useState("");
  return (
    <Page>
      <Pill text="EXPLORE AT YOUR PACE" />
      <Title>A little curiosity goes far.</Title>
      <Label muted>Choose a topic that feels useful to your day.</Label>
      <Field
        label="Find your practice"
        value={search}
        onChangeText={setSearch}
        placeholder="Everyday English, introductions…"
      />
      <QueryState query={catalog}>
        {(data) => (
          <View style={{ flexDirection: "row", flexWrap: "wrap", gap: 18 }}>
            {data
              .flatMap((l: any) => l.sets || [])
              .filter((set: any) =>
                set.title.toLowerCase().includes(search.toLowerCase()),
              )
              .map((set: any, i: number) => (
                <Card
                  key={set.id}
                  style={{ flexGrow: 1, flexBasis: 280, maxWidth: 520 }}
                  onPress={() =>
                    n.navigate("Player", {
                      path: `/sets/${set.id}`,
                      source: { set_id: set.id },
                    })
                  }
                >
                  <View
                    style={{
                      backgroundColor: [c.soft, c.peach, c.blue][i % 3],
                      padding: 20,
                      borderRadius: 18,
                      alignSelf: "flex-start",
                    }}
                  >
                    <Ionicons
                      name={
                        (
                          [
                            "chatbubbles-outline",
                            "sunny-outline",
                            "book-outline",
                          ] as const
                        )[i % 3]
                      }
                      size={30}
                      color={c.green}
                    />
                  </View>
                  <Pill text={`${set.level} · ${set.item_count} tasks`} />
                  <Title small>{set.title}</Title>
                  <Label muted>{set.about}</Label>
                  <Row>
                    <Label style={{ fontWeight: "700", color: c.green }}>
                      Let’s try it
                    </Label>
                    <Ionicons name="arrow-forward" size={18} color={c.green} />
                  </Row>
                </Card>
              ))}
          </View>
        )}
      </QueryState>
      <Title small>Go a little deeper</Title>
      <QueryState query={courses}>
        {(data) => {
          const list = [...data.mine, ...data.available].filter((v: any) =>
            v.title.toLowerCase().includes(search.toLowerCase()),
          );
          return list.length ? (
            list.map((course: any) => (
              <CourseCard key={course.id} course={course} navigation={n} />
            ))
          ) : (
            <Empty
              title="More paths are on their way"
              body="You can practise with the topic cards above while your instructor prepares a course."
            />
          );
        }}
      </QueryState>
    </Page>
  );
}
export function Review({ navigation: n }: any) {
  const q = useData("/me/review");
  return (
    <Page>
      <Pill text="A SECOND LOOK, A NEW PERSPECTIVE" />
      <Title>Make it stick.</Title>
      <Label muted>Short revisits help you put feedback into practice.</Label>
      <QueryState query={q}>
        {(data) =>
          data.items.length ? (
            <>
              <Button
                title={`Start ${data.items.length} review tasks`}
                onPress={() =>
                  n.navigate("Player", {
                    title: "Your review",
                    items: data.items,
                  })
                }
              />
              {data.items.map((item: any, i: number) => (
                <Card key={i}>
                  <Pill
                    text={item.kind === "listen" ? "Listening" : item.kind}
                  />
                  <Label style={{ fontWeight: "700" }}>
                    {item.kind === "listen"
                      ? "Listen and choose the matching sentence"
                      : item.prompt || item.text || item.words?.join(" ")}
                  </Label>
                  <Label muted>
                    {item.reason === "delayed_check_due"
                      ? "Enough time has passed for a fresh check."
                      : "Revisit this task from your previous practice."}
                  </Label>
                  <Row>
                    {item.evidence_ids?.slice(-3).map((id: number) => (
                      <Button
                        key={id}
                        title="See earlier attempt"
                        kind="quiet"
                        onPress={() => n.navigate("Attempt", { id })}
                      />
                    ))}
                  </Row>
                </Card>
              ))}
            </>
          ) : (
            <Empty
              title="You’re all caught up"
              body="There’s no review due right now. Explore something new, or take a well-earned break."
              action={
                <Button
                  title="Explore practice"
                  onPress={() => n.navigate("Practice")}
                />
              }
            />
          )
        }
      </QueryState>
    </Page>
  );
}
export function Progress({ navigation: n }: any) {
  const q = useData("/me/stats");
  const [cursor, setCursor] = useState<number | undefined>();
  const history = useData(`/me/attempts${cursor ? `?cursor=${cursor}` : ""}`);
  return (
    <Page>
      <Pill text="EVERY ATTEMPT COUNTS" />
      <Title>Look how far you’ve come.</Title>
      <QueryState query={q}>
        {(d) => (
          <>
            <Row>
              {[
                [d.attempts, "Practice attempts"],
                [d.streak_days || 0, "Day streak"],
                [
                  d.avg_score == null ? "—" : `${Math.round(d.avg_score)}%`,
                  "Average task score",
                ],
              ].map(([value, label]) => (
                <Card key={label} style={{ flex: 1, minWidth: 150 }}>
                  <Title>{value}</Title>
                  <Label muted>{label}</Label>
                </Card>
              ))}
            </Row>
            {d.weak_skills?.length > 0 && (
              <Card>
                <Title small>Your next focus</Title>
                {d.weak_skills
                  .filter((a: any) => !a.accent_only)
                  .map((skill: any) => (
                    <View key={skill.code}>
                      <Label style={{ fontWeight: "700" }}>{skill.label}</Label>
                      <Label muted>{skill.hint}</Label>
                    </View>
                  ))}
                <Button
                  title="Visit review"
                  kind="secondary"
                  onPress={() => n.navigate("Review")}
                />
              </Card>
            )}
          </>
        )}
      </QueryState>
      <Title small>Your practice journal</Title>
      <QueryState query={history}>
        {(d) =>
          d.items.length ? (
            <>
              {d.items.map((a: any) => (
                <Card
                  key={a.id}
                  onPress={() => n.navigate("Attempt", { id: a.id })}
                >
                  <Row style={{ justifyContent: "space-between" }}>
                    <Pill text={a.input_mode?.replaceAll("_", " ") || a.kind} />
                    <Label>{attemptScoreLabel(a)}</Label>
                  </Row>
                  <Label>{a.transcript || "Choice practice"}</Label>
                  <Label muted>
                    {a.created_at
                      ? new Date(a.created_at).toLocaleString()
                      : ""}
                    {a.disputed ? " · Excluded from skill evidence" : ""}
                  </Label>
                </Card>
              ))}
              <Row>
                {cursor && (
                  <Button
                    title="Newest attempts"
                    kind="secondary"
                    onPress={() => setCursor(undefined)}
                  />
                )}
                {d.next_cursor && (
                  <Button
                    title="Older attempts"
                    kind="secondary"
                    onPress={() => setCursor(d.next_cursor)}
                  />
                )}
              </Row>
            </>
          ) : (
            <Empty
              title="Your journal is ready"
              body="Complete your first practice task to see your feedback here."
            />
          )
        }
      </QueryState>
    </Page>
  );
}
