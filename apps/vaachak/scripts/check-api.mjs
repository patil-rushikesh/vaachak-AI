import fs from "node:fs";
const schema = JSON.parse(
  fs.readFileSync("../../postman/openapi.json", "utf8"),
);
const actual = JSON.parse(fs.readFileSync("src/api/operations.json", "utf8"));
const expected = {};
for (const [path, methods] of Object.entries(schema.paths))
  for (const [method, op] of Object.entries(methods))
    expected[op.operationId] = { method: method.toUpperCase(), path };
if (JSON.stringify(expected) !== JSON.stringify(actual))
  throw new Error(
    "API registry drift. Regenerate src/api/operations.json from postman/openapi.json.",
  );
console.log(
  `${Object.keys(actual).length} API operations match the backend contract.`,
);
