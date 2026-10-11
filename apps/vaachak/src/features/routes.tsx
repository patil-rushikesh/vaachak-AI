import React from "react";
import { router, useLocalSearchParams } from "expo-router";
import { useAuth } from "../providers/Auth";
import { Today, Practice, Review, Progress } from "./Learning";
import {
  Classes,
  ClassScreen,
  TeacherToday,
  Insights,
  Student,
  Assignment,
} from "./Classes";
import { Library, Course, CourseProgress } from "./Courses";
import { Player, AttemptScreen } from "./Player";
import { Composer, Recordings } from "./Composer";
import { Settings } from "./Settings";
import { Growth } from "./Growth";
import { Knowledge } from "./Knowledge";
import { Empty } from "../components/ui";
const transient = new Map<string, any>();
export const navigation = {
  navigate(name: string, params: any = {}) {
    let args = params;
    if (params.items || params.draft) {
      const id = String(Date.now()) + Math.random().toString(36);
      transient.set(id, params);
      if (transient.size > 30) transient.delete(transient.keys().next().value!);
      args = { transient: id };
    }
    router.navigate({
      pathname: name === "Today" ? "/" : "/[page]",
      params: { page: name, args: JSON.stringify(args) },
    });
  },
  goBack() {
    if (router.canGoBack()) router.back();
    else router.replace("/");
  },
};
export function RouteScreen({ home = false }: { home?: boolean }) {
  const { user } = useAuth();
  const query = useLocalSearchParams<{ page?: string; args?: string }>();
  const name = home ? "Today" : query.page || "Today";
  let params: any;
  try {
    params = JSON.parse(query.args || "{}");
  } catch {
    params = {};
  }
  if (params.transient) {
    params = transient.get(params.transient);
    if (!params)
      return (
        <Empty
          title="Reopen this practice"
          body="This temporary selection expired. Choose it again from Practice."
        />
      );
  }
  const common: Record<string, React.ComponentType<any>> = {
    Today: user?.role === "teacher" ? TeacherToday : Today,
    Classes,
    Class: ClassScreen,
    Course,
    Attempt: AttemptScreen,
    Settings,
    Growth,
  };
  const role: Record<string, React.ComponentType<any>> = user?.role ===
  "teacher"
    ? {
        Library,
        Knowledge,
        Insights,
        Student,
        Assignment,
        Composer,
        Recordings,
        CourseProgress,
      }
    : { Practice, Review, Progress, Player };
  const Screen = common[name] || role[name];
  if (!Screen)
    return (
      <Empty
        title="Page unavailable"
        body="Choose an activity from the navigation."
      />
    );
  return <Screen route={{ params }} navigation={navigation} />;
}
