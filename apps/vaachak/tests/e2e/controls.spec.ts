import skills from "../../src/api/skills.json";
import { test, expect } from "./fixtures";
test("reference selection, removal and uncertain publishing recovery", async ({
  page,
  request,
}) => {
  const email = `controls-${Date.now()}@example.invalid`,
    password = "Synthetic-Test-482!";
  const t = await (
    await request.post("/api/auth/register", {
      data: { name: "Control Tester", email, password, role: "teacher" },
    })
  ).json();
  const headers = { Authorization: `Bearer ${t.token}` };
  const cl = await (
    await request.post("/api/classes", {
      headers,
      data: { name: "Control classroom" },
    })
  ).json();
  const wav = Buffer.alloc(44 + 16000 * 2);
  wav.write("RIFF");
  wav.writeUInt32LE(wav.length - 8, 4);
  wav.write("WAVEfmt ", 8);
  wav.writeUInt32LE(16, 16);
  wav.writeUInt16LE(1, 20);
  wav.writeUInt16LE(1, 22);
  wav.writeUInt32LE(16000, 24);
  wav.writeUInt32LE(32000, 28);
  wav.writeUInt16LE(2, 32);
  wav.writeUInt16LE(16, 34);
  wav.write("data", 36);
  wav.writeUInt32LE(wav.length - 44, 40);
  const recording = await request.post("/api/recordings", {
    headers,
    multipart: {
      title: "Synthetic reference",
      duration_ms: "1000",
      file: { name: "reference.wav", mimeType: "audio/wav", buffer: wav },
    },
  });
  expect(recording.ok()).toBeTruthy();
  await page.goto("/");
  await page.getByLabel("Email", { exact: true }).fill(email);
  await page.getByLabel("Password", { exact: true }).fill(password);
  await page
    .getByRole("button", { name: "Let’s practise", exact: true })
    .click();
  await page.getByRole("tab", { name: "Classes", exact: true }).click();
  await page.getByRole("button", { name: /Control classroom/ }).click();
  await page
    .getByRole("button", { name: "Create assignment", exact: true })
    .click();
  await page.getByLabel("Title", { exact: true }).fill("Recoverable draft");
  await page
    .getByRole("button", { name: "Synthetic reference", exact: true })
    .click();
  await page.getByRole("button", { name: "None", exact: true }).click();
  await page.getByRole("button", { name: "+ read", exact: true }).click();
  await page.getByLabel("Sentence to read").fill("We learn together.");
  for (const skill of skills) {
    await page.getByRole("button", { name: skill.label, exact: true }).click();
    await page.getByRole("button", { name: skill.label, exact: true }).click();
  }
  await page
    .getByRole("switch", { name: "Approve task 1", exact: true })
    .click();
  await page.route(`**/api/classes/${cl.id}/assignments`, (route) =>
    route.request().method() === "POST"
      ? route.abort("failed")
      : route.continue(),
  );
  await page
    .getByRole("button", { name: "Publish assignment", exact: true })
    .click();
  await expect(page.getByRole("alert")).toBeVisible();
  await page
    .getByRole("button", { name: "Return and check saved work", exact: true })
    .click();
  await expect(
    page.getByRole("heading", { name: "Control classroom", exact: true }),
  ).toBeVisible();
  expect(
    await (
      await request.get(`/api/classes/${cl.id}/assignments`, { headers })
    ).json(),
  ).toEqual([]);
});
test("teacher invitation field and desktop account shortcut", async ({
  page,
  request,
}, info) => {
  await page.goto("/");
  await page
    .getByRole("button", { name: "New here? Create an account", exact: true })
    .click();
  await page.getByRole("button", { name: "Teacher", exact: true }).click();
  await page
    .getByLabel("Teacher invite (if required)")
    .fill("synthetic-invite");
  await page
    .getByRole("button", { name: "Already learning? Sign in", exact: true })
    .click();
  const email = `shortcut-${Date.now()}@example.invalid`,
    password = "Synthetic-Test-482!";
  await request.post("/api/auth/register", {
    data: { name: "Shortcut", email, password, role: "learner" },
  });
  await page.getByLabel("Email", { exact: true }).fill(email);
  await page.getByLabel("Password", { exact: true }).fill(password);
  await page
    .getByRole("button", { name: "Let’s practise", exact: true })
    .click();
  await page
    .getByRole("button", {
      name: info.project.name === "desktop" ? "My account" : "Open my account",
      exact: true,
    })
    .click();
  await expect(page.getByText("Your space. Your choices.")).toBeVisible();
});
test("screen recovery, speech mode switching and transcript editor", async ({
  page,
  request,
}) => {
  const password = "Synthetic-Test-482!",
    email = `modes-${Date.now()}@example.invalid`;
  const teacher = await (
    await request.post("/api/auth/register", {
      data: {
        name: "Modes teacher",
        email: "teacher-" + email,
        password,
        role: "teacher",
      },
    })
  ).json();
  const learner = await (
    await request.post("/api/auth/register", {
      data: { name: "Modes learner", email, password, role: "learner" },
    })
  ).json();
  const headers = { Authorization: `Bearer ${teacher.token}` };
  const cl = await (
    await request.post("/api/classes", {
      headers,
      data: { name: "Modes class" },
    })
  ).json();
  await request.post("/api/classes/join", {
    headers: { Authorization: `Bearer ${learner.token}` },
    data: { code: cl.code },
  });
  const a = await (
    await request.post(`/api/classes/${cl.id}/assignments`, {
      headers,
      data: {
        title: "Mode practice",
        items: [
          { kind: "read", text: "We learn together." },
          {
            kind: "build",
            words: ["We", "learn", "together"],
            answer: "We learn together",
          },
        ],
      },
    })
  ).json();
  await page.route("**/api/health", (route) =>
    route.fulfill({
      json: { ok: true, ai: false, server_speech_to_text: true, demo: false },
    }),
  );
  await page.goto("/");
  await page.getByLabel("Email", { exact: true }).fill(email);
  await page.getByLabel("Password", { exact: true }).fill(password);
  await page
    .getByRole("button", { name: "Let’s practise", exact: true })
    .click();
  await page.getByRole("tab", { name: "Class", exact: true }).click();
  await page.getByRole("button", { name: /Modes class/ }).click();
  // Deliberately malformed response tests the rendering boundary, not server behavior.
  await page.route(
    `**/api/assignments/${a.id}`,
    async (route) => {
      const response = await route.fetch();
      const data = await response.json();
      await route.fulfill({ json: { ...data, items: [null] } });
    },
    { times: 1 },
  );
  await page
    .getByRole("button", { name: "Start practice", exact: true })
    .click();
  await expect(page.getByText("Let’s take a fresh breath.")).toBeVisible();
  await page
    .getByRole("button", { name: "Reload this screen", exact: true })
    .click();
  await expect(
    page.getByRole("tab", { name: "Today", exact: true }),
  ).toBeVisible();
  await page.getByRole("tab", { name: "Class", exact: true }).click();
  await page.getByRole("button", { name: /Modes class/ }).click();
  await page
    .getByRole("button", { name: "Start practice", exact: true })
    .click();
  await expect(
    page.getByRole("button", { name: "Type instead", exact: true }),
  ).toBeVisible();
  await page.getByRole("button", { name: "Type instead", exact: true }).click();
  await page.getByLabel("Your answer").fill("We learn together.");
  await page.getByRole("button", { name: "Speak", exact: true }).click();
  // Controlled ASR preview exercises editing without treating synthetic microphone noise as speech.
  await page.route("**/api/transcriptions", (route) =>
    route.fulfill({
      json: {
        id: crypto.randomUUID(),
        transcript: "We learn togather.",
        original_transcript: "We learn togather.",
        status: "completed",
      },
    }),
  );
  await page
    .getByRole("button", { name: "Tap to record", exact: true })
    .click();
  await page.waitForTimeout(1600);
  await page.getByRole("button", { name: /^Stop recording ·/ }).click();
  await page.getByRole("button", {name:"Record again",exact:true}).click();
  await page.waitForTimeout(800);
  await page.getByRole("button", {name:/^Stop recording ·/}).click();
  await page
    .getByRole("button", { name: "Check my answer", exact: true })
    .click();
  await page.getByLabel("Confirm your transcript").fill("We learn together.");
  await expect(page.getByLabel("Confirm your transcript")).toHaveValue(
    "We learn together.",
  );
  await page.getByRole("button", { name: "Type instead", exact: true }).click();
  await page
    .getByRole("button", { name: "Check my answer", exact: true })
    .click();
  await expect(
    page.getByText("100% task score", { exact: true }),
  ).toBeVisible();
  await page
    .getByRole("button", { name: "Next small step", exact: true })
    .click();
  await page.getByRole("button", { name: "We", exact: true }).click();
  await page.getByRole("button", { name: "We", exact: true }).first().click();
  for (const word of ["We", "learn", "together"])
    await page.getByRole("button", { name: word, exact: true }).click();
  await page
    .getByRole("button", { name: "Check my answer", exact: true })
    .click();
  await expect(
    page.getByText("100% task score", { exact: true }),
  ).toBeVisible();
  await page
    .getByRole("button", { name: "Finish practice", exact: true })
    .click();
  await page
    .getByRole("button", { name: "Back to my day", exact: true })
    .click();
});
