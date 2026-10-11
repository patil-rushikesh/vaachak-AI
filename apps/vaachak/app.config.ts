import type { ExpoConfig, ConfigContext } from "expo/config";
export default ({ config }: ConfigContext): ExpoConfig => {
  const release = ["preview", "production"].includes(
    process.env.EAS_BUILD_PROFILE || "",
  );
  if (release && !process.env.EXPO_PUBLIC_API_URL?.startsWith("https://"))
    throw new Error(
      "Set EXPO_PUBLIC_API_URL to your deployed HTTPS API before creating a release.",
    );
  return { ...config, name: "Vaachak", slug: "vaachak" } as ExpoConfig;
};
