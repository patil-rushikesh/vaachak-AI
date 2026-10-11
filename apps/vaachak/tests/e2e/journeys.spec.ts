import { test, expect, Page, APIRequestContext } from "./fixtures";
const password = "Synthetic-Test-482!";
async function account(api: APIRequestContext, role = "learner") {
  const email = `ui-${role}-${Date.now()}-${Math.random().toString(36).slice(2)}@example.invalid`;
  const r = await api.post("/api/auth/register", {
    data: {
      name: role === "teacher" ? "Instructor Maya" : "Aarav",
      email,
      password,
      role,
    },
  });
  expect(r.ok()).toBeTruthy();
  return { ...(await r.json()), email };
}
async function login(page: Page, email: string) {
  await page.goto("/");
  await page.getByLabel("Email", { exact: true }).fill(email);
  await page.getByLabel("Password", { exact: true }).fill(password);
  await page
    .getByRole("button", { name: "Let’s practise", exact: true })
    .click();
  await expect(
    page.getByRole("tab", { name: "Today", exact: true }),
  ).toBeVisible();
}
async function setup(api: APIRequestContext) {
  const teacher = await account(api, "teacher"),
    learner = await account(api);
  const headers = { Authorization: `Bearer ${teacher.token}` };
  const cl = await (
    await api.post("/api/classes", {
      headers,
      data: { name: "Everyday confidence", standard: "adult" },
    })
  ).json();
  await api.post("/api/classes/join", {
    headers: { Authorization: `Bearer ${learner.token}` },
    data: { code: cl.code },
  });
  const items = [
    {
      kind: "choice",
      prompt: "She ___ home.",
      options: ["go", "goes"],
      correct: 1,
      explain: "Use goes with she.",
    },
    {
      kind: "fill",
      prompt: "Good ___.",
      options: ["morning", "mornings"],
      correct: 0,
    },
    {
      kind: "listen",
      text: "I live in Pune.",
      options: ["I live in Pune.", "I leave Pune."],
      correct: 0,
    },
    {
      kind: "build",
      words: ["We", "play", "cricket"],
      answer: "We play cricket",
    },
    { kind: "read", text: "The train is late." },
    { kind: "free", prompt: "Introduce yourself." },
  ];
  await api.post(`/api/classes/${cl.id}/assignments`, {
    headers,
    data: { title: "Six small steps", items },
  });
  return { teacher, learner, cl };
}
test("learner completes all six task formats, sees journal and settings", async ({
  page,
  request,
}) => {
  const { learner } = await setup(request);
  const errors: string[] = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await login(page, learner.email);
  await expect(page.getByText("Hello, Aarav")).toBeVisible();
  await page.getByRole("tab", { name: "Class", exact: true }).click();
  await page.getByRole("button", { name: /Everyday confidence/ }).click();
  await page
    .getByRole("button", { name: "Start practice", exact: true })
    .click();
  await page.getByRole("radio", { name: "B goes" }).click();
  await page.getByRole("button", { name: "Check my answer" }).click();
  await expect(
    page.getByText("100% task score", { exact: true }),
  ).toBeVisible();
  await page.getByRole("button", { name: "Next small step" }).click();
  await page.getByRole("radio", { name: "A morning" }).click();
  await page.getByRole("button", { name: "Check my answer" }).click();
  await page.getByRole("button", { name: "Next small step" }).click();
  await page.getByRole("button", { name: "Listen to the sentence" }).click();
  await page.getByRole("radio", { name: "A I live in Pune." }).click();
  await page.getByRole("button", { name: "Check my answer" }).click();
  await page.getByRole("button", { name: "Next small step" }).click();
  for (const word of ["We", "play", "cricket"])
    await page.getByRole("button", { name: word, exact: true }).click();
  await page.getByRole("button", { name: "Check my answer" }).click();
  await page.getByRole("button", { name: "Next small step" }).click();
  await page.getByRole("button", { name: "Type instead" }).click();
  await page.getByLabel("Your answer").fill("The train is late.");
  await page.getByRole("button", { name: "Check my answer" }).click();
  await page.getByRole("button", { name: "Next small step" }).click();
  await page.getByRole("button", { name: "Type instead" }).click();
  await page
    .getByLabel("Your answer")
    .fill("I am Aarav. I enjoy learning English with my friends.");
  await page.getByRole("button", { name: "Check my answer" }).click();
  await page.getByRole("button", { name: "Finish practice" }).click();
  await expect(
    page.getByText("A little more confident.", { exact: true }),
  ).toBeVisible();
  await page.getByRole("button", { name: "See my progress" }).click();
  await expect(page.getByText("Your practice journal")).toBeVisible();
  await page.getByRole("button", { name: "Open my account" }).click();
  await page.getByLabel("Timezone", { exact: true }).fill("Asia/Kolkata");
  await page.getByRole("button", { name: "Save preferences" }).click();
  await expect(page.getByText("Your preferences are saved.")).toBeVisible();
  expect(errors).toEqual([]);
});
test("teacher creates, reviews and publishes a lesson", async ({
  page,
  request,
}) => {
  const t = await account(request, "teacher");
  await login(page, t.email);
  await page.getByRole("tab", { name: "Library", exact: true }).click();
  await page.getByLabel("New course title").fill("English for real life");
  await page.getByRole("button", { name: "Create a draft course" }).click();
  await page.getByLabel("New unit title").fill("First conversations");
  await page.getByRole("button", { name: "Add unit", exact: true }).click();
  await page.getByRole("button", { name: "Add lesson", exact: true }).click();
  await page.getByLabel("Title", { exact: true }).fill("Say hello");
  await page.getByRole("button", { name: "+ read", exact: true }).click();
  await page.getByLabel("Sentence to read").fill("Hello, my name is Maya.");
  await expect(
    page.getByRole("button", { name: "Save lesson draft" }),
  ).toBeDisabled();
  await page.getByRole("switch", { name: "Approve task 1" }).click();
  await page.getByRole("button", { name: "Save lesson draft" }).click();
  await expect(page.getByText("Say hello", { exact: true })).toBeVisible();
  await page
    .getByRole("button", { name: "Publish course", exact: true })
    .click();
  await expect(page.getByText("A1 · published", { exact: true })).toBeVisible();
});
test("lost submission response is reconciled without a duplicate", async ({
  page,
  request,
}) => {
  const { learner } = await setup(request);
  await login(page, learner.email);
  await page.getByRole("tab", { name: "Class", exact: true }).click();
  await page.getByRole("button", { name: /Everyday confidence/ }).click();
  await page
    .getByRole("button", { name: "Start practice", exact: true })
    .click();
  await page.getByRole("radio", { name: "B goes" }).click();
  await page.route(
    "**/api/attempts",
    async (route) => {
      await route.fetch();
      await route.abort("failed");
    },
    { times: 1 },
  );
  await page.getByRole("button", { name: "Check my answer" }).click();
  await expect(
    page.getByRole("button", { name: "Check submission status" }),
  ).toBeVisible();
  await page.getByRole("button", { name: "Check submission status" }).click();
  await expect(
    page.getByText("100% task score", { exact: true }),
  ).toBeVisible();
  const history = await (
    await request.get("/api/me/attempts", {
      headers: { Authorization: `Bearer ${learner.token}` },
    })
  ).json();
  expect(history.items).toHaveLength(1);
});
test("invalid sign-in is readable and never exposes server internals", async ({
  page,
}) => {
  await page.goto("/");
  await page
    .getByLabel("Email", { exact: true })
    .fill("missing@example.invalid");
  await page.getByLabel("Password", { exact: true }).fill("wrongpass");
  await page.getByRole("button", { name: "Let’s practise" }).click();
  await expect(page.getByRole("alert")).toBeVisible();
  await expect(
    page.getByText("Support reference:", { exact: false }),
  ).toBeVisible();
  await expect(page.getByText("Traceback", { exact: false })).toHaveCount(0);
});
test("teacher sees class evidence and publishes a targeted follow-up", async ({
  page,
  request,
}) => {
  const { teacher, learner, cl } = await setup(request);
  await login(page, teacher.email);
  await page.getByRole("button", { name: "Open class insights" }).click();
  await expect(page.getByText("Evidence into encouragement.")).toBeVisible();
  await page.getByRole("button", { name: "Set a follow-up" }).first().click();
  await page.getByLabel("Title", { exact: true }).fill("A helpful first step");
  await page.getByRole("button", { name: "+ choice", exact: true }).click();
  await page.getByLabel("Prompt", { exact: true }).fill("She ___ English.");
  await page.getByLabel("Option 1", { exact: true }).fill("likes");
  await page.getByLabel("Option 2", { exact: true }).fill("like");
  await page.getByRole("switch", { name: "Approve task 1" }).click();
  await page.getByRole("button", { name: "Publish assignment" }).click();
  await expect(page.getByText("Follow-up journal")).toBeVisible();
  const headers = { Authorization: `Bearer ${teacher.token}` };
  const actions = await (
    await request.get(`/api/classes/${cl.id}/attention/actions`, { headers })
  ).json();
  expect(
    actions.items.some(
      (a: any) => a.assignment_id && a.student_id === learner.user.id,
    ),
  ).toBe(true);
});
test("learner joins a class from a code and can recover a failed query", async ({
  page,
  request,
}) => {
  const t = await account(request, "teacher"),
    l = await account(request);
  const cl = await (
    await request.post("/api/classes", {
      headers: { Authorization: `Bearer ${t.token}` },
      data: { name: "A fresh learning circle" },
    })
  ).json();
  await login(page, l.email);
  await page.getByRole("tab", { name: "Class", exact: true }).click();
  await page.getByLabel("Class code").fill(cl.code);
  await page.getByRole("button", { name: "Join class", exact: true }).click();
  await expect(
    page.getByRole("heading", { name: "A fresh learning circle" }),
  ).toBeVisible();
  await page.route("**/api/catalog", (route) =>
    route.fulfill({
      status: 503,
      contentType: "application/json",
      body: JSON.stringify({
        error: {
          code: "unavailable",
          message: "Practice is temporarily unavailable.",
          request_id: "synthetic-test",
        },
      }),
    }),
  );
  await page.getByRole("tab", { name: "Practice", exact: true }).click();
  await expect(
    page.getByText("Practice is temporarily unavailable."),
  ).toBeVisible();
  await page.unroute("**/api/catalog");
  await page.getByRole("button", { name: "Try again", exact: true }).click();
  await expect(
    page.getByText("Everyday sentences", { exact: true }),
  ).toBeVisible();
});
test("pending practice survives browser reload and sign-in", async ({
  page,
  request,
}) => {
  const { learner } = await setup(request);
  await login(page, learner.email);
  await page.getByRole("tab", { name: "Class", exact: true }).click();
  await page.getByRole("button", { name: /Everyday confidence/ }).click();
  await page
    .getByRole("button", { name: "Start practice", exact: true })
    .click();
  await page.getByRole("radio", { name: "B goes" }).click();
  await page.route(
    "**/api/attempts",
    async (route) => {
      await route.fetch();
      await route.abort("failed");
    },
    { times: 1 },
  );
  await page.getByRole("button", { name: "Check my answer" }).click();
  await expect(
    page.getByRole("button", { name: "Check submission status" }),
  ).toBeVisible();
  await login(page, learner.email);
  await page.getByRole("button", { name: "Recover pending practice" }).click();
  await expect(
    page.getByText("100% task score", { exact: true }),
  ).toBeVisible();
});
test("teacher records synthetic browser audio and saves a valid voice reference", async ({
  page,
  request,
}) => {
  const teacher = await account(request, "teacher");
  await login(page, teacher.email);
  await page.getByRole("tab", { name: "Library", exact: true }).click();
  await page.getByRole("button", { name: "Voice reference library" }).click();
  await page.getByLabel("Recording title").fill("Synthetic voice reference");
  await page.getByRole("button", { name: "Record a voice reference" }).click();
  await page.waitForTimeout(1600);
  await page.getByRole("button", { name: /Stop ·/ }).click();
  await expect(
    page.getByRole("button", { name: "Play recording" }),
  ).toBeVisible();
  await page.getByRole("button", { name: "Save recording" }).click();
  await expect(
    page.getByRole("heading", { name: "Synthetic voice reference" }),
  ).toBeVisible();
});

test("unsent submission can be edited after status confirms absence", async ({
  page,
  request,
}) => {
  const { learner } = await setup(request);
  await login(page, learner.email);
  await page.getByRole("tab", { name: "Class", exact: true }).click();
  await page.getByRole("button", { name: /Everyday confidence/ }).click();
  await page
    .getByRole("button", { name: "Start practice", exact: true })
    .click();
  await page.getByRole("radio", { name: "A go", exact: true }).click();
  await page.route("**/api/attempts", (route) => route.abort("failed"), {
    times: 1,
  });
  await page.getByRole("button", { name: "Check my answer" }).click();
  await page.getByRole("button", { name: "Check submission status" }).click();
  await expect(
    page.getByText(
      "The server has no saved submission. You can safely submit this answer again.",
    ),
  ).toBeVisible();
  await page.getByRole("radio", { name: "B goes", exact: true }).click();
  await page.getByRole("button", { name: "Check my answer" }).click();
  await expect(
    page.getByText("100% task score", { exact: true }),
  ).toBeVisible();
});

test("goal preferences, offline download, guided conversation and feedback", async ({
  page,
  request,
}) => {
  const learner = await account(request);
  await login(page, learner.email);
  await page
    .getByRole("button", {
      name: "My goals & continuous practice",
      exact: true,
    })
    .click();
  await page
    .getByRole("button", { name: "Interview confidence", exact: true })
    .click();
  await expect(
    page.getByRole("button", { name: "✓ Interview confidence", exact: true }),
  ).toBeVisible();
  await page
    .getByRole("button", { name: "Download public practice", exact: true })
    .click();
  await expect(
    page.getByRole("button", { name: "Remove download", exact: true }),
  ).toBeVisible();
  await page.context().setOffline(true);
  await page.getByRole("button", { name: "practises", exact: true }).click();
  await expect(page.getByText("That’s right.", { exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Next offline activity", exact: true }).click();
  await expect(page.getByText(/2\/.*I worked ___ this project/)).toBeVisible();
  await page.context().setOffline(false);
  await page
    .getByRole("button", { name: "Start a guided conversation", exact: true })
    .click();
  for (let i = 0; i < 4; i++) {
    await page
      .getByLabel("Your conversation reply", { exact: true })
      .fill("I built a useful project with my team.");
    await page
      .getByRole("button", { name: "Continue conversation", exact: true })
      .click();
    await expect(page.getByText("I built a useful project with my team.", { exact: true })).toHaveCount(i + 1);
  }
  await expect(
    page.getByRole("button", { name: "Try another conversation", exact: true }),
  ).toBeVisible();
  await page
    .getByLabel("Your feedback", { exact: true })
    .fill("These prompts helped me prepare.");
  await page
    .getByRole("button", { name: "Send product feedback", exact: true })
    .click();
  await expect(
    page.getByText("Thank you. Your report has been recorded for review.", {
      exact: true,
    }),
  ).toBeVisible();
  await page
    .getByRole("button", { name: "Start my next practice", exact: true })
    .click();
  await expect(page.getByText("1 of 5", { exact: true })).toBeVisible();
  await page.getByRole("tab", { name: "Today", exact: true }).click();
  await page
    .getByRole("button", {
      name: "My goals & continuous practice",
      exact: true,
    })
    .click();
  await expect(
    page.getByRole("button", { name: /Resume Interview confidence/ }),
  ).toBeVisible();
});

test("teacher draft survives navigation and reopens with the saved title", async ({
  page,
  request,
}) => {
  const { teacher } = await setup(request);
  await login(page, teacher.email);
  await page.getByRole("tab", { name: "Classes", exact: true }).click();
  await page.getByRole("button", { name: /Everyday confidence/ }).click();
  await page
    .getByRole("button", { name: "Create assignment", exact: true })
    .click();
  await page.getByLabel("Title", { exact: true }).fill("A draft worth keeping");
  await page.getByRole("button", { name: "Save draft", exact: true }).click();
  await expect(
    page.getByText("Draft saved. You can return from Saved work.", {
      exact: true,
    }),
  ).toBeVisible();
  await page
    .getByRole("button", { name: "Open my account", exact: true })
    .click();
  await page
    .getByRole("button", { name: "Saved drafts & archives", exact: true })
    .click();
  await page.getByRole("button", { name: "Resume draft", exact: true }).click();
  await expect(page.getByRole("textbox", { name: "Title", exact: true })).toHaveValue(
    "A draft worth keeping",
  );
});

test("guest can get a useful correction without signing up", async ({
  page,
}) => {
  await page.goto("/");
  await page
    .getByRole("button", { name: "Try a free 2-minute sample", exact: true })
    .click();
  await page.getByRole("button", { name: "practise", exact: true }).click();
  await expect(
    page.getByText("One useful correction.", { exact: true }),
  ).toBeVisible();
  await page.getByRole("button", { name: "Next sample", exact: true }).click();
  await expect(
    page.getByText("Choose a polite request.", { exact: true }),
  ).toBeVisible();
});
