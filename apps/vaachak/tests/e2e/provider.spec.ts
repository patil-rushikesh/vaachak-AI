import { test, expect } from "./fixtures";
test("live teacher AI generation, queued draft and human approval gate", async ({
  page,
  request,
}) => {
  test.skip(
    !process.env.E2E_LIVE_PROVIDER,
    "Requires isolated AI-enabled test backend and worker",
  );
  test.setTimeout(120000);
  const email = `live-${Date.now()}@example.invalid`,
    password = "Synthetic-Test-482!";
  const t = await (
    await request.post("/api/auth/register", {
      data: { name: "Live QA Instructor", email, password, role: "teacher" },
    })
  ).json();
  const headers = { Authorization: `Bearer ${t.token}` };
  await request.post("/api/classes", {
    headers,
    data: { name: "Live QA classroom" },
  });
  await page.goto("/");
  await page.getByLabel("Email", { exact: true }).fill(email);
  await page.getByLabel("Password", { exact: true }).fill(password);
  await page
    .getByRole("button", { name: "Let’s practise", exact: true })
    .click();
  await page.getByRole("tab", { name: "Classes", exact: true }).click();
  await page.getByRole("button", { name: /Live QA classroom/ }).click();
  await page
    .getByRole("button", { name: "Create assignment", exact: true })
    .click();
  await page.getByLabel("Title", { exact: true }).fill("Provider test draft");
  await page
    .getByLabel("Topic", { exact: true })
    .fill("Introducing yourself politely");
  await page
    .getByRole("button", { name: "Draft three tasks", exact: true })
    .click();
  await expect(page.getByRole("switch", { name: /Approve task/ })).toHaveCount(
    3,
    { timeout: 90000 },
  );
  await expect(
    page.getByRole("button", { name: "Publish assignment", exact: true }),
  ).toBeDisabled();
  await page
    .getByRole("button", { name: "Queue AI draft", exact: true })
    .click();
  await expect(async () => {
    await page
      .getByRole("button", { name: "Check queued draft", exact: true })
      .click();
    await expect(
      page.getByRole("switch", { name: /Approve task/ }),
    ).toHaveCount(7);
  }).toPass({ timeout: 90000, intervals: [1000, 3000, 5000] });
  await expect(
    page.getByRole("button", { name: "Publish assignment", exact: true }),
  ).toBeDisabled();
  await page.getByRole("button", { name: "Save draft", exact: true }).click();
  await expect(
    page.getByText("Draft saved. You can return from Saved work."),
  ).toBeVisible();
});
