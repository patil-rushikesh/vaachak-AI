import { describe, expect, it } from "vitest";
import { validateReleaseEnvironment } from "../scripts/release-config";

describe("release API configuration", () => {
  it.each([undefined, "", "http://api.onrender.com", "https://localhost", "https://127.0.0.1", "https://10.0.2.2", "https://api.local", "https://api.example.com", "https://api.onrender.com/api", "https://user:secret@api.onrender.com", "https://api.onrender.com?key=secret", "https://api.onrender.com#api"])("rejects an unusable release origin: %s", (url) => {
    expect(() => validateReleaseEnvironment({ VAACHAK_RELEASE: "1", EXPO_PUBLIC_API_URL: url })).toThrow();
  });
  it.each(["preview", "production", "apk", "ios-simulator"])("guards the %s mobile profile", (profile) => {
    expect(() => validateReleaseEnvironment({ EAS_BUILD_PROFILE: profile })).toThrow();
  });
  it("guards Vercel builds", () => {
    expect(() => validateReleaseEnvironment({ VERCEL: "1" })).toThrow();
  });
  it("accepts a hosted HTTPS API origin", () => {
    expect(() => validateReleaseEnvironment({ VAACHAK_RELEASE: "1", EXPO_PUBLIC_API_URL: "https://vaachak-api.onrender.com" })).not.toThrow();
  });
  it("preserves local development", () => {
    expect(() => validateReleaseEnvironment({ EXPO_PUBLIC_API_URL: "http://localhost:8000" })).not.toThrow();
    expect(() => validateReleaseEnvironment({})).not.toThrow();
  });
});
