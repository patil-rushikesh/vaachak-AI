import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { isDeepStrictEqual } from "node:util";

const app = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const root = path.resolve(app, "../..");
const python =
  process.env.PYTHON ||
  [".venv313/bin/python", ".venv/bin/python"]
    .map((p) => path.join(root, p))
    .find(fs.existsSync) ||
  "python3";
// Import OpenAPI without starting the service or touching its database.
const live = JSON.parse(
  execFileSync(
    python,
    [path.join(root, "tools/export_postman.py"), "--schema-only"],
    {
      encoding: "utf8",
      maxBuffer: 8 * 1024 * 1024,
      env: { ...process.env, GROQ_API_KEY: "", VAACHAK_GROQ_KEY: "" },
    },
  ),
);
const saved = JSON.parse(
  fs.readFileSync(path.join(root, "postman/openapi.json"), "utf8"),
);
if (!isDeepStrictEqual(live, saved)) {
  throw new Error(
    "Backend OpenAPI drift. Run tools/export_postman.py before regenerating the client artifacts.",
  );
}
const expected = {};
for (const [route, methods] of Object.entries(live.paths)) {
  for (const [method, operation] of Object.entries(methods)) {
    if (operation.operationId)
      expected[operation.operationId] = {
        method: method.toUpperCase(),
        path: route,
      };
  }
}
const registry = path.join(app, "src/api/operations.json");
if (process.argv.includes("--write-registry"))
  fs.writeFileSync(registry, JSON.stringify(expected, null, 2) + "\n");
const actual = JSON.parse(fs.readFileSync(registry, "utf8"));
if (!isDeepStrictEqual(expected, actual)) {
  throw new Error(
    "API registry drift. Run node scripts/check-api.mjs --write-registry and regenerate schema.d.ts.",
  );
}
console.log(
  `${Object.keys(actual).length} API operations match freshly imported backend OpenAPI.`,
);
