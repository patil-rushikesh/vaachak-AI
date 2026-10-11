import { spawnSync } from "node:child_process";
import { validateReleaseEnvironment } from "./release-config.js";

process.env.VAACHAK_RELEASE = "1";
validateReleaseEnvironment(process.env);
const result = spawnSync(process.execPath, ["node_modules/expo/bin/cli", "export", "--platform", "web"], {
  stdio: "inherit",
  env: process.env,
});
if (result.error) throw result.error;
process.exit(result.status ?? 1);
