import { test, expect, Page, APIRequestContext } from "./fixtures";
const password = "Synthetic-Test-482!";
async function signIn(
  page: Page,
  request: APIRequestContext,
  role = "teacher",
) {
  const email = `notes-${Date.now()}-${Math.random().toString(36).slice(2)}@example.invalid`;
  const response = await request.post("/api/auth/register", {
    data: { name: "Note Tester", email, password, role },
  });
  expect(response.ok()).toBeTruthy();
  const account = await response.json();
  await page.goto("/");
  await page.getByLabel("Email", { exact: true }).fill(email);
  await page.getByLabel("Password", { exact: true }).fill(password);
  await page
    .getByRole("button", { name: "Let’s practise", exact: true })
    .click();
  await expect(
    page.getByRole("tab", { name: "Today", exact: true }),
  ).toBeVisible();
  return { Authorization: `Bearer ${account.token}` };
}
async function openNotes(page: Page) {
  await page.getByRole("tab", { name: "Library", exact: true }).click();
  await page
    .getByRole("button", { name: "Teaching notes", exact: true })
    .click();
}
async function reviewPublish(page: Page) {
  await page
    .getByRole("button", { name: "Mark as reviewed", exact: true })
    .click();
  await page
    .getByRole("button", { name: "I have reviewed this note", exact: true })
    .click();
  await expect(
    page.getByText("Reviewed · only you", { exact: true }),
  ).toBeVisible();
  await page
    .getByRole("button", { name: "Publish teaching note", exact: true })
    .click();
  await page
    .getByRole("button", { name: "Publish to shared library", exact: true })
    .click();
  await expect(
    page.getByText("Published · shared", { exact: true }),
  ).toBeVisible();
}

test("teacher creates, retries, reviews, publishes, edits and withdraws a teaching note", async ({
  page,
  request,
}) => {
  const headers = await signIn(page, request);
  await openNotes(page);
  await page
    .getByRole("button", { name: "Write a teaching note", exact: true })
    .click();
  await expect(
    page.getByRole("button", { name: "Save private draft", exact: true }),
  ).toBeDisabled();
  await page.getByLabel("Note title", { exact: true }).fill("Everyday verbs");
  await page
    .getByLabel("Explanation", { exact: true })
    .fill("With she and he, use likes in the simple present.");
  await page
    .getByLabel("Example (optional)", { exact: true })
    .fill("She likes tea.");
  await page
    .getByRole("button", { name: "Skill: He, she, it verbs", exact: true })
    .click();
  await page.getByLabel("Find a skill", { exact: true }).fill("He, she");
  await page
    .getByRole("button", { name: "He, she, it verbs", exact: true })
    .click();
  await page.getByRole("button", { name: "A2", exact: true }).click();
  let fail = true;
  // Forward the first save but drop its response: retry must not create a duplicate.
  await page.route("**/api/teacher/knowledge", async (route) => {
    if (route.request().method() === "POST" && fail) {
      fail = false;
      await route.fetch();
      return route.fulfill({
        status: 503,
        contentType: "application/json",
        body: JSON.stringify({
          error: {
            message: "Save confirmation interrupted. Retry safely.",
            request_id: "test-save-recovery",
          },
        }),
      });
    }
    await route.continue();
  });
  await page
    .getByRole("button", { name: "Save private draft", exact: true })
    .click();
  await expect(
    page.getByText("Save confirmation interrupted. Retry safely."),
  ).toBeVisible();
  await expect(page.getByLabel("Explanation", { exact: true })).toHaveValue(
    "With she and he, use likes in the simple present.",
  );
  await page
    .getByRole("button", { name: "Save private draft", exact: true })
    .click();
  await expect(
    page.getByText("Draft · only you", { exact: true }),
  ).toBeVisible();
  const notes = (
    await (await request.get("/api/teacher/knowledge", { headers })).json()
  ).units.filter((n: any) => n.can_manage);
  expect(notes).toHaveLength(1);
  await page
    .getByRole("button", { name: "Mark as reviewed", exact: true })
    .click();
  await page.getByRole("button", { name: "Cancel", exact: true }).click();
  await reviewPublish(page);
  await page
    .getByRole("button", { name: "Edit teaching note", exact: true })
    .click();
  await expect(page.getByText(/Saving changes withdraws/)).toBeVisible();
  await page
    .getByLabel("Example (optional)", { exact: true })
    .fill("He likes coffee.");
  await page
    .getByRole("button", { name: "Save private draft", exact: true })
    .click();
  await expect(
    page.getByText("Draft · only you", { exact: true }),
  ).toBeVisible();
  await expect(page.getByText("A2 · v2", { exact: true })).toBeVisible();
  await reviewPublish(page);
  await page
    .getByRole("button", { name: "Withdraw teaching note", exact: true })
    .click();
  await page
    .getByRole("button", { name: "Withdraw this note", exact: true })
    .click();
  await expect(
    page.getByText("Withdrawn · only you", { exact: true }),
  ).toBeVisible();
  await page
    .getByRole("button", { name: "Refresh notes", exact: true })
    .click();
  await page
    .getByRole("button", { name: "Shared library", exact: true })
    .click();
  await page
    .getByLabel("Search teaching notes", { exact: true })
    .fill("Everyday verbs");
  await expect(
    page.getByText("No matching notes", { exact: true }),
  ).toBeVisible();
  await page.getByLabel("Search teaching notes", { exact: true }).fill("");
  await page
    .getByRole("button", { name: /^Open / })
    .first()
    .click();
  await expect(
    page.getByRole("button", { name: "Edit teaching note", exact: true }),
  ).toHaveCount(0);
});

test("stale edit shows a recoverable conflict and keeps the teacher's text", async ({
  page,
  request,
}) => {
  const headers = await signIn(page, request);
  const draft = {
    title: "Versioned note",
    body: "Use she goes in a sentence.",
    skill_code: "MORPH.AGREEMENT",
  };
  const note = await (
    await request.post("/api/teacher/knowledge", { headers, data: draft })
  ).json();
  await openNotes(page);
  await page
    .getByRole("button", { name: "Open Versioned note", exact: true })
    .click();
  await page
    .getByRole("button", { name: "Edit teaching note", exact: true })
    .click();
  await request.put(`/api/teacher/knowledge/${note.id}`, {
    headers,
    data: { ...draft, version: 1, body: "Updated on another device." },
  });
  await page
    .getByLabel("Explanation", { exact: true })
    .fill("My unsaved explanation.");
  await page
    .getByRole("button", { name: "Save private draft", exact: true })
    .click();
  await expect(page.getByText(/The note changed. Refresh/)).toBeVisible();
  await expect(page.getByLabel("Explanation", { exact: true })).toHaveValue(
    "My unsaved explanation.",
  );
  await page
    .getByRole("button", { name: "Back to teaching notes", exact: true })
    .click();
  await page.getByRole("button", { name: "Cancel", exact: true }).click();
  await expect(page.getByLabel("Explanation", { exact: true })).toHaveValue(
    "My unsaved explanation.",
  );
  await page
    .getByRole("button", { name: "Back to teaching notes", exact: true })
    .click();
  await page.getByRole("button", { name: "Leave editor", exact: true }).click();
  await page
    .getByRole("button", { name: "Refresh notes", exact: true })
    .click();
  await expect(
    page.getByText("Updated on another device.", { exact: true }),
  ).toBeVisible();
});

test("learner can inspect grounded feedback and cannot access the teacher editor", async ({
  page,
  request,
}) => {
  const headers = await signIn(page, request, "learner");
  const response = await request.post("/api/attempts", {
    headers,
    multipart: {
      set_id: "en-present-agreement",
      item_index: "0",
      transcript: "She goes to school.",
    },
  });
  expect(response.ok()).toBeTruthy();
  const attempt = await response.json();
  // Only provider-derived fields are simulated; auth, submission and attempt retrieval use the real API.
  await page.route(`**/api/attempts/${attempt.id}`, async (route) => {
    const original = await route.fetch();
    await route.fulfill({
      response: original,
      json: {
        ...(await original.json()),
        source: "ai",
        basis: "word_accuracy",
        next_line: "Try a sentence about your day.",
        sources: [
          {
            id: "fixture-reviewed-note",
            title: "Reviewed verb explanation",
            source: "Teacher note",
            version: 2,
          },
        ],
      },
    });
  });
  await page.getByRole("tab", { name: "Progress", exact: true }).click();
  await page.getByRole("button", { name: /She goes to school/ }).click();
  await page
    .getByRole("button", { name: "Why this feedback?", exact: true })
    .click();
  await expect(
    page.getByText("Reviewed verb explanation", { exact: true }),
  ).toBeVisible();
  await expect(
    page.getByText("Teacher note · Version 2", { exact: true }),
  ).toBeVisible();
  await expect(page.getByText(/does not measure your accent/)).toBeVisible();
  await expect(
    page.getByText("Try a sentence about your day.", { exact: true }),
  ).toBeVisible();
  await page
    .getByRole("button", { name: "Hide feedback details", exact: true })
    .click();
  await expect(
    page.getByText("Reviewed verb explanation", { exact: true }),
  ).toHaveCount(0);
  expect((await request.get("/api/teacher/knowledge", { headers })).status()).toBe(403);
});
