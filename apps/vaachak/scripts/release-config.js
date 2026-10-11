/** Values here are public build configuration, never server-side secrets. */
function validateReleaseEnvironment(env) {
  const release = env.VAACHAK_RELEASE === "1" || env.VERCEL === "1" ||
    ["preview", "production", "apk", "ios-simulator"].includes(env.EAS_BUILD_PROFILE || "");
  if (!release) return;
  let url;
  try {
    url = new URL(env.EXPO_PUBLIC_API_URL || "");
  } catch {
    throw new Error("Set EXPO_PUBLIC_API_URL to the deployed HTTPS API origin before building a release.");
  }
  const hostname = url.hostname.toLowerCase();
  if (url.protocol !== "https:" || url.username || url.password ||
      (url.pathname !== "/" && url.pathname !== "") || url.search || url.hash ||
      hostname === "localhost" || hostname.endsWith(".localhost") ||
      hostname.endsWith(".local") || hostname.includes(":") ||
      /^\d+\.\d+\.\d+\.\d+$/.test(hostname) ||
      hostname === "example.com" || hostname.endsWith(".example.com") ||
      hostname.endsWith(".invalid")) {
    throw new Error("EXPO_PUBLIC_API_URL must be a deployed HTTPS origin, without credentials, /api, paths, query strings, or a local/test address.");
  }
}

module.exports = { validateReleaseEnvironment };
