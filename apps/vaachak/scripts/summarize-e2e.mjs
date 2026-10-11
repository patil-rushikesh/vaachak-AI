import fs from "node:fs";
const reports = (process.argv.slice(2).length ? process.argv.slice(2) : ["test-results/e2e-results.json"]).map(file => JSON.parse(fs.readFileSync(file, "utf8")));
const tests = [];
const observed = [];
function visit(s) {
  for (const spec of s.specs || [])
    for (const t of spec.tests || []) {
      const result = t.results.at(-1);
      tests.push({
        name: spec.title,
        project: t.projectName,
        status: result?.status,
      });
      if (result?.status === "passed")
        for (const a of result.attachments || [])
          if (a.name === "controls" && a.body) {
            const p = JSON.parse(Buffer.from(a.body, "base64").toString());
            for (const c of p.controls)
              observed.push({ ...c, test: spec.title, project: t.projectName });
          }
    }
  for (const child of s.suites || []) visit(child);
}
for (const report of reports) visit(report);
const inventory = JSON.parse(
  fs.readFileSync(
    "../../docs/verification/frontend/control-inventory.json",
    "utf8",
  ),
);
for (const control of inventory) {
  const literal = /^"(.*)"$/.exec(control.label)?.[1];
  const matches = literal
    ? observed.filter(
        (c) => c.label === literal || c.label.endsWith(" " + literal),
      )
    : [];
  control.status = matches.length
    ? "label exercised in passing web test"
    : "not established by label audit";
  control.tests = [...new Set(matches.map((c) => c.test))];
}
const result = {
  generatedAt: new Date().toISOString(),
  tests,
  visitedPaths: [...new Set(observed.map((x) => x.page))].sort(),
  observedControls: observed,
  inventory,
  notes: [
    "Label matching is evidence of interaction, not proof of every conditional state or platform.",
    "Native flows and live provider evidence are recorded separately.",
    "Input values and URL query parameters are excluded.",
  ],
};
fs.writeFileSync(
  "../../docs/verification/frontend/full-control-audit.json",
  JSON.stringify(result, null, 2) + "\n",
);
console.log(
  JSON.stringify(
    {
      tests: tests.length,
      passed: tests.filter((t) => t.status === "passed").length,
      visitedPaths: result.visitedPaths,
      literalControls: inventory.filter((c) => /^"/.test(c.label)).length,
      literalControlsObserved: inventory.filter((c) => c.tests.length).length,
    },
    null,
    2,
  ),
);
console.log(
  "Unobserved literal controls:",
  inventory
    .filter((c) => /^"/.test(c.label) && !c.tests.length)
    .map((c) => `${c.file}:${c.line} ${c.label}`)
    .join("\n"),
);
