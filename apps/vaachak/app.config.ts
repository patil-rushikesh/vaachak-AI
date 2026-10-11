import type { ExpoConfig, ConfigContext } from "expo/config";
import { validateReleaseEnvironment } from "./scripts/release-config";
export default ({ config }: ConfigContext): ExpoConfig => {
  validateReleaseEnvironment(process.env);
  return { ...config, name: "Vaachak", slug: "vaachak" } as ExpoConfig;
};
