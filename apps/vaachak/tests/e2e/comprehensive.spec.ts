import { test, expect, Page, APIRequestContext } from "./fixtures";
const password = "Synthetic-Test-482!";
async function account(api: APIRequestContext, role = "learner") {
  const email = `full-${role}-${Date.now()}-${Math.random().toString(36).slice(2)}@example.invalid`;
  const r = await api.post("/api/auth/register", {
    data: { name: "Full Test", email, password, role },
  });
  expect(r.ok()).toBeTruthy();
  return { ...(await r.json()), email };
}
async function login(page: Page, email: string, pass = password) {
  await page.goto("/");
  await page.getByLabel("Email", { exact: true }).fill(email);
  await page.getByLabel("Password", { exact: true }).fill(pass);
  await page
    .getByRole("button", { name: "Let’s practise", exact: true })
    .click();
  await expect(
    page.getByRole("tab", { name: "Today", exact: true }),
  ).toBeVisible();
}
const button = (page: Page, name: string) =>
  page.getByRole("button", { name, exact: true });
async function confirm(page: Page, title: string) {
  await button(page, title).click();
  await button(page, "Confirm").click();
}
async function course(api: APIRequestContext, t: any) {
  const headers = { Authorization: `Bearer ${t.token}` };
  const title = `Full test course ${Date.now()}-${Math.random().toString(36).slice(2, 6)}`;
  const r = await api.post("/api/courses", {
    headers,
    data: { title, level: "A1", visibility: "public", sequential: true },
  });
  expect(r.ok()).toBeTruthy();
  return { headers, title, ...(await r.json()) };
}
test("account preferences validation, export, password rotation and deletion", async ({
  page,
  request,
}) => {
  const a = await account(request);
  await login(page, a.email);
  await button(page, "Open my account").click();
  await page.getByLabel("Timezone", { exact: true }).fill("Invalid/Timezone");
  await button(page, "Save preferences").click();
  await expect(page.getByRole("alert")).toBeVisible();
  await button(page, "Use device timezone").click();
  await page.getByRole("switch", { name: "Optional research consent" }).click();
  await button(page, "Save preferences").click();
  await expect(page.getByText("Your preferences are saved.")).toBeVisible();
  const download = page.waitForEvent("download");
  await button(page, "Export my data").click();
  expect((await download).suggestedFilename()).toBe("vaachak-my-data.json");
  await page
    .getByLabel("Current password", { exact: true })
    .fill("wrong-password");
  await page
    .getByLabel("New password (at least 8 characters)", { exact: true })
    .fill(password + "New");
  await button(page, "Change password & sign out").click();
  await expect(page.getByRole("alert")).toBeVisible();
  await page.getByLabel("Current password", { exact: true }).fill(password);
  await button(page, "Change password & sign out").click();
  await expect(page.getByLabel("Email", { exact: true })).toBeVisible();
  await login(page, a.email, password + "New");
  await button(page, "Open my account").click();
  await page.getByLabel("Password to confirm deletion").fill(password + "New");
  await button(page, "Delete my account").click();
  await button(page, "Cancel").click();
  await button(page, "Delete my account").click();
  await button(page, "Permanently delete").click();
  await expect(page.getByLabel("Email", { exact: true })).toBeVisible();
  const r = await request.post("/api/auth/login", {
    data: { email: a.email, password: password + "New" },
  });
  expect(r.status()).toBe(401);
});
test("registration roles, validation, reset errors and return to sign in", async ({
  page,
}) => {
  await page.goto("/");
  await button(page, "New here? Create an account").click();
  await expect(button(page, "Create account")).toBeDisabled();
  await button(page, "Class learner").click();
  await button(page, "Teacher").click();
  await expect(page.getByLabel("Teacher invite (if required)")).toBeVisible();
  await button(page, "Independent").click();
  await page.getByLabel("Your name").fill("New Learner");
  await page
    .getByLabel("Email", { exact: true })
    .fill(`registration-${Date.now()}@example.invalid`);
  await page.getByLabel("Password", { exact: true }).fill(password);
  await button(page, "Create account").click();
  await expect(
    page.getByRole("tab", { name: "Today", exact: true }),
  ).toBeVisible();
  await button(page, "Open my account").click();
  await button(page, "Sign out").click();
  await button(page, "Forgot password?").click();
  await page
    .getByLabel("Recovery email")
    .fill(`missing-${Date.now()}@example.invalid`);
  await button(page, "Email me reset instructions").click();
  await expect(
    page.getByText(/Email recovery is not configured/),
  ).toBeVisible();
  await page.getByLabel("Reset token").fill("invalid-token");
  await page.getByLabel("New password", { exact: true }).fill(password);
  await button(page, "Reset password").click();
  await expect(page.getByRole("alert")).toBeVisible();
  await button(page, "Already learning? Sign in").click();
  await expect(page.getByLabel("Email", { exact: true })).toBeVisible();
});
test("course details, visibility, ordering, unit management and deletion dialogs", async ({
  page,
  request,
}) => {
  const t = await account(request, "teacher");
  const c = await course(request, t);
  await login(page, t.email);
  await page.getByRole("tab", { name: "Library", exact: true }).click();
  await page.getByRole("button", { name: new RegExp(c.title) }).click();
  await page.getByLabel("Updated title").fill("Updated full course");
  await page.getByLabel("Updated summary").fill("A tested learning path");
  await button(page, "Save details").click();
  await expect(
    page.getByRole("heading", { name: "Updated full course" }),
  ).toBeVisible();
  await button(page, "Limit to assigned classes").click();
  await expect(button(page, "Make publicly discoverable")).toBeVisible();
  await button(page, "Make publicly discoverable").click();
  await button(page, "Allow any lesson order").click();
  await expect(button(page, "Require lesson order")).toBeVisible();
  await button(page, "Require lesson order").click();
  for (const title of ["Unit One", "Unit Two"]) {
    await page.getByLabel("New unit title").fill(title);
    await button(page, "Add unit").click();
    await expect(page.getByRole("heading", { name: title })).toBeVisible();
  }
  await page.getByLabel("Rename unit").first().fill("Renamed One");
  await button(page, "Rename").first().click();
  await button(page, "Move unit down").first().click();
  await expect(page.getByLabel("Rename unit").first()).toHaveAttribute(
    "placeholder",
    "Unit Two",
  );
  await button(page, "Move unit up").last().click();
  await button(page, "Course progress").click();
  await expect(page.getByText("How your course is growing.")).toBeVisible();
  await page.goBack();
  await button(page, "Delete unused unit").last().click();
  await button(page, "Cancel").click();
  await button(page, "Delete unused unit").last().click();
  await button(page, "Confirm").click();
  await confirm(page, "Delete unused course");
  await expect(
    page.getByRole("tab", { name: "Library", exact: true }),
  ).toBeVisible();
  expect(
    (
      await request.get(`/api/courses/${c.id}`, { headers: c.headers })
    ).status(),
  ).toBe(404);
});
test("class code rotation, assignment update, learner removal and archives", async ({
  page,
  request,
}) => {
  const t = await account(request, "teacher"),
    l = await account(request);
  const headers = { Authorization: `Bearer ${t.token}` };
  await login(page, t.email);
  await page.getByRole("tab", { name: "Classes", exact: true }).click();
  await page.getByLabel("Class name").fill("Managed classroom");
  await button(page, "Create class").click();
  const classes = await (await request.get("/api/classes", { headers })).json();
  const cl = classes.find((c: any) => c.name === "Managed classroom");
  await confirm(page, "Refresh joining code");
  const updated = await (
    await request.get(`/api/classes/${cl.id}`, { headers })
  ).json();
  expect(updated.code).not.toBe(cl.code);
  await request.post("/api/classes/join", {
    headers: { Authorization: `Bearer ${l.token}` },
    data: { code: updated.code },
  });
  const assignment = await (
    await request.post(`/api/classes/${cl.id}/assignments`, {
      headers,
      data: {
        title: "Managed assignment",
        items: [{ kind: "read", text: "Hello everyone." }],
      },
    })
  ).json();
  await login(page, t.email);
  await page.getByRole("tab", { name: "Classes", exact: true }).click();
  await page.getByRole("button", { name: /Managed classroom/ }).click();
  await button(page, "View & manage").click();
  await page
    .getByLabel("New title", { exact: true })
    .fill("Updated assignment");
  await button(page, "Update title").click();
  await expect(
    page.getByRole("heading", { name: "Updated assignment" }),
  ).toBeVisible();
  await confirm(page, "Archive assignment");
  await button(page, "Open my account").click();
  await button(page, "Saved drafts & archives").click();
  await button(page, "Restore Updated assignment").click();
  await page.getByRole("tab", { name: "Classes", exact: true }).click();
  await page.getByRole("button", { name: /Managed classroom/ }).click();
  await confirm(page, "Remove from class");
  await button(page, "View & manage").click();
  await confirm(page, "Delete unused assignment");
  expect(
    (
      await request.get(`/api/assignments/${assignment.id}`, { headers })
    ).status(),
  ).toBe(404);
  await confirm(page, "Archive class");
  await button(page, "Open my account").click();
  await button(page, "Saved drafts & archives").click();
  await button(page, "Restore Managed classroom").click();
});
test("download refresh, wrong/right answers, removal and offline fallback", async ({
  page,
  request,
  context,
}) => {
  const l = await account(request);
  await login(page, l.email);
  await button(page, "My goals & continuous practice").click();
  await button(page, "Download public practice").click();
  await button(page, "Refresh practice download").click();
  const pack = await (
    await request.get("/api/practice-download", {
      headers: { Authorization: `Bearer ${l.token}` },
    })
  ).json();
  const item = pack.items[0];
  await button(
    page,
    item.options[(item.correct + 1) % item.options.length],
  ).click();
  await expect(page.getByText(/Try this:/)).toBeVisible();
  await button(page, "Next offline activity").click();
  await context.setOffline(true);
  await expect(page.getByText("Practice for a quiet connection")).toBeVisible({
    timeout: 30000,
  });
  const next = pack.items[1];
  await button(page, next.options[next.correct]).click();
  await expect(page.getByText("That’s right.")).toBeVisible();
  await button(page, "Next offline activity").click();
  await button(page, "Remove download").click();
  await expect(
    page.getByText("No saved practice available yet."),
  ).toBeVisible();
  await context.setOffline(false);
});
test("growth goals, difficulty, weekly targets, consent, reminders and product feedback", async ({
  page,
  request,
}) => {
  const l = await account(request);
  await login(page, l.email);
  await button(page, "My goals & continuous practice").click();
  for (const label of [
    "Interview confidence",
    "Workplace conversations",
    "Project presentations",
    "Everyday English",
  ]) {
    await button(page, label).click();
    await expect(button(page, "✓ " + label)).toBeVisible();
  }
  await button(page, "Stretch myself").click();
  await expect(button(page, "✓ Stretch myself")).toBeVisible();
  await button(page, "Build foundations").click();
  for (const days of [2, 3, 5, 7]) {
    await button(page, `${days} days`).click();
    await expect(
      page.getByText(`Optional weekly goal: ${days} days.`, { exact: false }),
    ).toBeVisible();
  }
  await page
    .getByRole("switch", { name: "Share optional usage events" })
    .click();
  await page
    .getByRole("switch", { name: "Share optional usage events" })
    .click();
  await page.getByLabel("Reminder hour (07–21, device local time)").fill("10");
  await button(page, "Enable daily reminder").click();
  await expect(page.getByRole("alert")).toBeVisible();
  await button(page, "Pause reminders").click();
  await expect(page.getByText("Practice reminders are off.")).toBeVisible();
  await page
    .getByLabel("Your feedback", { exact: true })
    .fill("Synthetic test: controls checked");
  await button(page, "Send product feedback").click();
  await expect(page.getByText(/Thank you/)).toBeVisible();
  await button(page, "Start a guided conversation").click();
  await button(page, "Reload conversation status").click();
  for (let i = 0; i < 4; i++) {
    await page
      .getByLabel("Your conversation reply")
      .fill("I enjoy learning with my team.");
    await button(page, "Continue conversation").click();
  }
  await expect(button(page, "Try another conversation")).toBeVisible();
  await button(page, "Try another conversation").click();
  await expect(button(page, "Start a guided conversation")).toBeVisible();
});
test("composer all task editors, validation, option controls and draft persistence", async ({
  page,
  request,
}) => {
  const t = await account(request, "teacher"),
    headers = { Authorization: `Bearer ${t.token}` };
  const cl = await (
    await request.post("/api/classes", {
      headers,
      data: { name: "Editor class" },
    })
  ).json();
  await login(page, t.email);
  await page.getByRole("tab", { name: "Classes", exact: true }).click();
  await page.getByRole("button", { name: /Editor class/ }).click();
  await button(page, "Create assignment").click();
  await page.getByLabel("Title", { exact: true }).fill("All editor controls");
  await page
    .getByLabel("Instructions", { exact: true })
    .fill("Read each task carefully.");
  await page.getByLabel("Due date (optional)").fill("2026-12-01");
  for (const kind of ["read", "free", "build", "choice", "fill", "listen"]) {
    await button(page, "+ " + kind).click();
  }
  await page.getByLabel("Explanation").first().fill("A useful explanation");
  await page.getByLabel("Sentence to read").fill("I learn every day.");
  await page
    .getByLabel("Prompt", { exact: true })
    .first()
    .fill("Talk about your day.");
  await page.getByLabel("Words (separate with |)").fill("We|learn|together");
  await page.getByLabel("Correct sentence").fill("We learn together");
  const prompts = page.getByLabel("Prompt", { exact: true });
  await prompts.nth(1).fill("She ___ English.");
  await page.getByLabel("Prompt (include ___ for the blank)").fill("Good ___.");
  await page.getByLabel("Sentence to speak aloud").fill("Hello there.");
  for (let i = 0; i < 3; i++) {
    await page.getByLabel("Option 1", { exact: true }).nth(i).fill("Correct");
    await page.getByLabel("Option 2", { exact: true }).nth(i).fill("Other");
  }
  await button(page, "Add option").first().click();
  await page.getByLabel("Option 3", { exact: true }).fill("Third");
  await button(page, "Remove last option").first().click();
  await button(page, "Set as correct answer").first().click();
  for (let i = 1; i <= 6; i++)
    await page
      .getByRole("switch", { name: `Approve task ${i}`, exact: true })
      .click();
  await button(page, "Save draft").click();
  await expect(page.getByText(/Draft saved/)).toBeVisible();
  await button(page, "Remove task").last().click();
  await button(page, "Publish assignment").click();
  await expect(
    page.getByRole("heading", { name: "Editor class" }),
  ).toBeVisible();
  const list = await (
    await request.get(`/api/classes/${cl.id}/assignments`, { headers })
  ).json();
  expect(list.some((a: any) => a.title === "All editor controls")).toBe(true);
});
test("course lesson movement, edit, archive restoration, publish and enroll lifecycle", async ({
  page,
  request,
}) => {
  const t = await account(request, "teacher"),
    l = await account(request);
  const c = await course(request, t);
  const unit = await (
    await request.post(`/api/courses/${c.id}/units`, {
      headers: c.headers,
      data: { title: "Lesson unit" },
    })
  ).json();
  for (const title of ["First lesson", "Second lesson"])
    expect(
      (
        await request.post(`/api/units/${unit.id}/lessons`, {
          headers: c.headers,
          data: {
            title,
            items: [
              {
                kind: "choice",
                prompt: "Choose yes",
                options: ["Yes", "No"],
                correct: 0,
              },
            ],
          },
        })
      ).ok(),
    ).toBeTruthy();
  await login(page, t.email);
  await page.getByRole("tab", { name: "Library", exact: true }).click();
  await page.getByRole("button", { name: new RegExp(c.title) }).click();
  await button(page, "Move down").first().click();
  await page
    .getByText("First lesson", { exact: true })
    .locator("..")
    .locator("..")
    .getByRole("button", { name: "Move up", exact: true })
    .click();
  await page.route("**/api/lessons/*", async (route) => {
    if (route.request().method() === "GET")
      await new Promise((resolve) => setTimeout(resolve, 600));
    await route.continue();
  });
  await button(page, "Edit lesson").first().click();
  await expect(page.getByText("Loading lesson…")).toBeVisible();
  await expect(page.getByLabel("Title", { exact: true })).toHaveCount(0);
  await page.getByLabel("Title", { exact: true }).fill("Edited lesson");
  await button(page, "Save lesson").click();
  await expect(page.getByText("Edited lesson", { exact: true })).toBeVisible();
  await button(page, "Publish course").click();
  await button(page, "Unpublish course").click();
  await button(page, "Publish course").click();
  await button(page, "Open my account").click();
  await button(page, "Sign out").click();
  await login(page, l.email);
  await page.getByRole("tab", { name: "Practice", exact: true }).click();
  await page.getByRole("button", { name: new RegExp(c.title) }).click();
  await button(page, "Add to my learning").click();
  await page.getByRole("tab", { name: "Today", exact: true }).click();
  await button(page, "See all").click();
  await page.getByRole("button", { name: new RegExp(c.title) }).click();
  await expect(button(page, "Finish the previous lesson")).toBeDisabled();
  await button(page, "Start lesson").click();
  await page.getByRole("radio", { name: "A Yes" }).click();
  await button(page, "Check my answer").click();
  await button(page, "Finish practice").click();
  await button(page, "Keep practising").click();
  await page.getByRole("tab", { name: "Practice", exact: true }).click();
  await page.getByRole("button", { name: new RegExp(c.title) }).click();
  await expect(button(page, "Practise again")).toBeVisible();
  await button(page, "Practise again").click();
  await expect(button(page, "Check my answer")).toBeVisible();
  await page.getByRole("tab", { name: "Practice", exact: true }).click();
  await page.getByRole("button", { name: new RegExp(c.title) }).click();
  await confirm(page, "Leave course");
});
test("teacher evidence, attention snooze and resolve controls", async ({
  page,
  request,
}) => {
  const t = await account(request, "teacher"),
    l = await account(request),
    l2 = await account(request);
  const headers = { Authorization: `Bearer ${t.token}` };
  const cl = await (
    await request.post("/api/classes", {
      headers,
      data: { name: "Attention classroom" },
    })
  ).json();
  for (const a of [l, l2])
    await request.post("/api/classes/join", {
      headers: { Authorization: `Bearer ${a.token}` },
      data: { code: cl.code },
    });
  await login(page, t.email);
  await button(page, "Open class insights").click();
  await button(page, "See evidence").first().click();
  await expect(button(page, "Set personal follow-up")).toBeVisible();
  await page.goBack();
  await button(page, "Snooze for a day").first().click();
  await button(page, "Cancel").click();
  await button(page, "Snooze for a day").first().click();
  await button(page, "Confirm").click();
  await expect(button(page, "Snooze for a day")).toHaveCount(1);
  await expect(button(page, "Confirm")).toHaveCount(0);
  await button(page, "Mark resolved").first().click();
  await button(page, "Confirm").click();
  await expect(page.getByText("Nothing flagged right now")).toBeVisible();
});
test("learner wrong answer, retry comparison, ratings and history", async ({
  page,
  request,
}) => {
  const t = await account(request, "teacher"),
    l = await account(request),
    headers = { Authorization: `Bearer ${t.token}` };
  const cl = await (
    await request.post("/api/classes", {
      headers,
      data: { name: "Retry classroom" },
    })
  ).json();
  await request.post("/api/classes/join", {
    headers: { Authorization: `Bearer ${l.token}` },
    data: { code: cl.code },
  });
  await request.post(`/api/classes/${cl.id}/assignments`, {
    headers,
    data: {
      title: "Retry task",
      items: [
        {
          kind: "choice",
          prompt: "She ___ home.",
          options: ["go", "goes"],
          correct: 1,
          skills: ["MORPH.AGREEMENT"],
        },
      ],
    },
  });
  await login(page, l.email);
  await page.getByRole("tab", { name: "Class", exact: true }).click();
  await page.getByRole("button", { name: /Retry classroom/ }).click();
  await button(page, "Start practice").click();
  await page.getByRole("radio", { name: "A go", exact: true }).click();
  await button(page, "Check my answer").click();
  await button(page, "Needs improvement").click();
  await expect(
    page.getByText("Thank you. Your feedback helps improve the next activity."),
  ).toBeVisible();
  await button(page, "Try this again").click();
  await page.getByRole("radio", { name: "B goes", exact: true }).click();
  await button(page, "Check my answer").click();
  await button(page, "Yes, useful").click();
  await button(page, "Finish practice").click();
  await button(page, "See my progress").click();
  await page
    .getByRole("button", { name: /100% task score/ })
    .first()
    .click();
  await expect(page.getByText("Your practice, revisited.")).toBeVisible();
  await button(page, "Compare the first attempt").click();
  await expect(
    page.getByText("0% task score", { exact: true }).filter({ visible: true }),
  ).toBeVisible();
  await page.getByRole("button", { name: /See follow-up attempt/ }).click();
  await expect(
    page
      .getByText("100% task score", { exact: true })
      .filter({ visible: true }),
  ).toBeVisible();
});
test("teacher course assignment, unassignment, course and lesson archive restore", async ({
  page,
  request,
}) => {
  const t = await account(request, "teacher");
  const c = await course(request, t);
  const cl = await (
    await request.post("/api/classes", {
      headers: c.headers,
      data: { name: "Course linking class" },
    })
  ).json();
  const u = await (
    await request.post(`/api/courses/${c.id}/units`, {
      headers: c.headers,
      data: { title: "Archive unit" },
    })
  ).json();
  const lesson = await (
    await request.post(`/api/units/${u.id}/lessons`, {
      headers: c.headers,
      data: {
        title: "Archive lesson",
        items: [{ kind: "read", text: "Hello today." }],
      },
    })
  ).json();
  await request.post(`/api/courses/${c.id}/publish`, {
    headers: c.headers,
    data: { published: true },
  });
  await login(page, t.email);
  await page.getByRole("tab", { name: "Classes", exact: true }).click();
  await page.getByRole("button", { name: /Course linking class/ }).click();
  await button(page, "Assign a course").click();
  await button(page, "Assign to this class").click();
  await button(page, "Confirm").click();
  await expect(button(page, "Unassign course")).toBeVisible();
  await confirm(page, "Unassign course");
  await expect(button(page, "Unassign course")).toHaveCount(0);
  await page.getByRole("tab", { name: "Library", exact: true }).click();
  await page.getByRole("button", { name: new RegExp(c.title) }).click();
  await button(page, "Edit lesson").click();
  await confirm(page, "Archive lesson");
  await button(page, "Open my account").click();
  await button(page, "Saved drafts & archives").click();
  await button(page, "Restore Archive lesson").click();
  await page.getByRole("tab", { name: "Library", exact: true }).click();
  await page.getByRole("button", { name: new RegExp(c.title) }).click();
  await button(page, "Edit lesson").click();
  const deleted = page.waitForResponse(
    (response) => response.url().endsWith(`/api/lessons/${lesson.id}`) &&
      response.request().method() === "DELETE",
  );
  await confirm(page, "Delete unused lesson");
  expect((await deleted).ok()).toBeTruthy();
  expect(
    (
      await request.get(`/api/lessons/${lesson.id}`, { headers: c.headers })
    ).status(),
  ).toBe(404);
  await confirm(page, "Archive course");
  await button(page, "Open my account").click();
  await button(page, "Saved drafts & archives").click();
  await button(page, "Restore " + c.title).click();
  expect(
    (
      await request.get(`/api/classes/${cl.id}/courses`, { headers: c.headers })
    ).ok(),
  ).toBeTruthy();
});
test("personal starting check saves a draft, resumes, completes and starts another session", async ({
  page,
  request,
}) => {
  const l = await account(request);
  await login(page, l.email);
  await button(page, "My goals & continuous practice").click();
  const response = page.waitForResponse(
    (r) =>
      r.url().endsWith("/api/me/practice-sessions") &&
      r.request().method() === "POST",
  );
  await button(page, "Try a starting check").click();
  const data = await (await response).json();
  await expect(button(page, "Check my answer")).toBeVisible();
  const radios = page.getByRole("radio");
  if (await radios.count()) {
    await radios.first().click();
    await expect(page.getByText(/Answer draft saved/)).toBeVisible();
  }
  await page.getByRole("tab", { name: "Today", exact: true }).click();
  await button(page, "My goals & continuous practice").click();
  await page
    .getByRole("button", { name: /Resume .*0\// })
    .first()
    .click();
  for (let i = 0; i < data.items.length; i++) {
    const item = data.items[i];
    if (["choice", "fill", "listen"].includes(item.kind))
      await page.getByRole("radio").first().click();
    else if (item.kind === "build") {
      for (const word of item.words) await button(page, word).first().click();
    } else {
      await button(page, "Type instead").click();
      await page
        .getByLabel("Your answer")
        .fill(item.text || "I learn English with my friends.");
    }
    await button(page, "Check my answer").click();
    await expect(
      page.getByText(/% task score/).filter({ visible: true }),
    ).toBeVisible();
    await button(
      page,
      i === data.items.length - 1 ? "Finish practice" : "Next small step",
    ).click();
  }
  await expect(page.getByText("A little more confident.")).toBeVisible();
  await button(page, "Keep practising").click();
  await button(page, "Start my next practice").click();
  await expect(button(page, "Check my answer")).toBeVisible();
  await page.getByRole("tab", { name: "Today", exact: true }).click();
  await button(page, "My goals & continuous practice").click();
  await button(page, "Practise due revision").click();
  await expect(button(page, "Check my answer")).toBeVisible();
});
test("practice search, review empty state and invalid classroom error", async ({
  page,
  request,
}, info) => {
  const l = await account(request);
  await login(page, l.email);
  await page.getByRole("tab", { name: "Practice", exact: true }).click();
  await page.getByLabel("Find your practice").fill("does-not-exist");
  await expect(
    page.getByText("Everyday sentences", { exact: true }),
  ).toHaveCount(0);
  await page.getByLabel("Find your practice").fill("Everyday");
  await expect(
    page.getByText("Everyday sentences", { exact: true }),
  ).toBeVisible();
  if (info.project.name === "desktop") {
    await button(page, "My review").click();
    await expect(page.getByText("You’re all caught up")).toBeVisible();
    await button(page, "Explore practice").click();
  }
  await page.getByRole("tab", { name: "Class", exact: true }).click();
  await page.getByLabel("Class code").fill("NOT-A-CODE");
  await button(page, "Join class").click();
  await expect(page.getByRole("alert")).toBeVisible();
});
test("guest sample cycles through every question and restarts", async ({
  page,
}) => {
  await page.goto("/");
  await button(page, "Try a free 2-minute sample").click();
  for (const [i, answer] of [
    "practise",
    "Could you explain that again, please?",
    "on",
  ].entries()) {
    await button(page, answer).click();
    await button(
      page,
      i === 2 ? "Try the sample again" : "Next sample",
    ).click();
  }
  await expect(button(page, "practises")).toBeVisible();
  await button(page, "Continue to sign in").click();
  await expect(page.getByLabel("Email", { exact: true })).toBeVisible();
});
test("history pagination returns to newest attempts", async ({
  page,
  request,
}) => {
  const t = await account(request, "teacher"),
    l = await account(request),
    headers = { Authorization: `Bearer ${t.token}` };
  const cl = await (
    await request.post("/api/classes", {
      headers,
      data: { name: "History classroom" },
    })
  ).json();
  await request.post("/api/classes/join", {
    headers: { Authorization: `Bearer ${l.token}` },
    data: { code: cl.code },
  });
  const a = await (
    await request.post(`/api/classes/${cl.id}/assignments`, {
      headers,
      data: {
        title: "History task",
        items: [
          {
            kind: "choice",
            prompt: "Choose yes",
            options: ["Yes", "No"],
            correct: 0,
          },
        ],
      },
    })
  ).json();
  for (let i = 0; i < 21; i++) {
    const r = await request.post("/api/attempts", {
      headers: { Authorization: `Bearer ${l.token}` },
      multipart: {
        assignment_id: String(a.id),
        item_index: "0",
        choice: "0",
        client_uuid: crypto.randomUUID(),
      },
    });
    expect(r.ok()).toBeTruthy();
  }
  await login(page, l.email);
  await page.getByRole("tab", { name: "Progress", exact: true }).click();
  await button(page, "Older attempts").click();
  await expect(button(page, "Newest attempts")).toBeVisible();
  await button(page, "Newest attempts").click();
  await expect(button(page, "Older attempts")).toBeVisible();
});
test("voice reference playback and deletion with confirmation cancellation", async ({
  page,
  request,
}) => {
  const t = await account(request, "teacher");
  await login(page, t.email);
  await page.getByRole("tab", { name: "Library", exact: true }).click();
  await button(page, "Voice reference library").click();
  await page.getByLabel("Recording title").fill("Disposable voice reference");
  await button(page, "Record a voice reference").click();
  await page.waitForTimeout(3000);
  await page.getByRole("button", { name: /^Stop ·/ }).click();
  await button(page, "Play recording").click();
  await button(page, "Pause recording").click();
  await button(page, "Save recording").click();
  await expect(
    page.getByText("Disposable voice reference", { exact: true }),
  ).toBeVisible();
  await button(page, "Delete reference recording").click();
  await button(page, "Cancel").click();
  await confirm(page, "Delete reference recording");
  await expect(page.getByText("Your voice library starts here")).toBeVisible();
});

test("teacher secondary navigation and personal follow-up entry", async ({
  page,
  request,
}) => {
  const t = await account(request, "teacher"),
    l = await account(request),
    headers = { Authorization: `Bearer ${t.token}` };
  await login(page, t.email);
  await button(page, "Create my first class").click();
  await page.getByLabel("Class name").fill("Navigation class");
  await button(page, "Create class").click();
  const cl = (await (await request.get("/api/classes", { headers })).json())[0];
  await request.post("/api/classes/join", {
    headers: { Authorization: `Bearer ${l.token}` },
    data: { code: cl.code },
  });
  await login(page, t.email);
  await page.getByRole("tab", { name: "Classes", exact: true }).click();
  await page.getByRole("button", { name: /Navigation class/ }).click();
  await button(page, "Learner insights").click();
  await expect(page.getByText("Skills to revisit")).toBeVisible();
  await page.goBack();
  await button(page, "View learning evidence").click();
  await button(page, "Set personal follow-up").click();
  await expect(
    page.getByText("PERSONAL FOLLOW-UP", { exact: true }),
  ).toBeVisible();
  await page.goBack();
  await page.goBack();
  await button(page, "Learner insights").click();
  await button(page, "Snooze for a day").first().click();
  await button(page, "Confirm").click();
  await expect(button(page, "Open learner").first()).toBeVisible();
  await button(page, "Open learner").first().click();
  await expect(button(page, "Set personal follow-up")).toBeVisible();
});
test("review evidence navigation and complete revision task", async ({
  page,
  request,
}) => {
  const t = await account(request, "teacher"),
    l = await account(request),
    headers = { Authorization: `Bearer ${t.token}` };
  const cl = await (
    await request.post("/api/classes", {
      headers,
      data: { name: "Review class" },
    })
  ).json();
  await request.post("/api/classes/join", {
    headers: { Authorization: `Bearer ${l.token}` },
    data: { code: cl.code },
  });
  const a = await (
    await request.post(`/api/classes/${cl.id}/assignments`, {
      headers,
      data: {
        title: "Review source",
        items: [
          { kind: "read", text: "He goes home.", skills: ["MORPH.AGREEMENT"] },
        ],
      },
    })
  ).json();
  await (
    await request.post("/api/attempts", {
      headers: { Authorization: `Bearer ${l.token}` },
      multipart: {
        assignment_id: String(a.id),
        item_index: "0",
        transcript: "He go home.",
        client_uuid: crypto.randomUUID(),
      },
    })
  ).json();
  await login(page, l.email);
  await button(page, "Open my classes").click();
  await expect(
    page.getByRole("button", { name: /Review class/ }),
  ).toBeVisible();
  await page.getByRole("tab", { name: "Progress", exact: true }).click();
  await button(page, "Visit review").click();
  await button(page, "See earlier attempt").first().click();
  await expect(page.getByText("Your practice, revisited.")).toBeVisible();
  await page.goBack();
  await page.getByRole("button", { name: /Start .* review tasks/ }).click();
  await button(page, "Type instead").click();
  await page.getByLabel("Your answer").fill("He goes home.");
  await button(page, "Check my answer").click();
  await button(page, "Finish practice").click();
  await button(page, "Back to my day").click();
  await expect(
    page.getByText("Hello, Full").filter({ visible: true }),
  ).toBeVisible();
});
