// SDK 57 uses CommonJS query-string 7. The security-fixed URI decoder is ESM.
// Keep the upstream decoder, adapting only this import until Expo upgrades it.
import fs from "node:fs";
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const target = require.resolve("query-string");
const original = "const decodeComponent = require('decode-uri-component');";
const replacement = "const decoder = require('decode-uri-component');\nconst decodeComponent = decoder.default || decoder; // Vaachak: ESM decoder compatibility";
const source = fs.readFileSync(target, "utf8");
if (source.includes(replacement)) process.exit(0);
if (!source.includes(original)) {
  throw new Error("query-string changed: review and remove/update the SDK 57 decoder compatibility patch.");
}
fs.writeFileSync(target, source.replace(original, replacement));
