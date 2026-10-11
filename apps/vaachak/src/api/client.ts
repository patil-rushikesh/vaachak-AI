import { Platform } from "react-native";
import operations from "./operations.json";

export const API_URL = (
  process.env.EXPO_PUBLIC_API_URL ||
  (Platform.OS === "web"
    ? ""
    : Platform.OS === "android"
      ? "http://10.0.2.2:8000"
      : "http://127.0.0.1:8000")
).replace(/\/$/, "");
let token: string | null = null;
let expired: () => void = () => {};
export const setSession = (value: string | null, onExpired?: () => void) => {
  token = value;
  if (onExpired) expired = onExpired;
};
export const authHeaders = (): Record<string, string> =>
  token ? { Authorization: `Bearer ${token}` } : {};
export class ApiError extends Error {
  constructor(
    public status: number,
    public code: string,
    message: string,
    public requestId?: string,
  ) {
    super(message);
  }
}
export async function request<T = any>(
  path: string,
  options: RequestInit = {},
): Promise<T> {
  const sessionAtStart = token;
  const controller = new AbortController();
  const timer = setTimeout(
    () => controller.abort(),
    path.includes("/attempts") ||
      path.includes("/transcriptions") ||
      path.includes("/ai/")
      ? 150000
      : 90000,
  );
  try {
    const response = await fetch(`${API_URL}/api${path}`, {
      ...options,
      signal: controller.signal,
      headers: {
        ...authHeaders(),
        ...(options.body && !(options.body instanceof FormData)
          ? { "Content-Type": "application/json" }
          : {}),
        ...options.headers,
      },
    });
    const data = await response.json().catch(() => ({}));
    if (!response.ok) {
      if (
        response.status === 401 &&
        sessionAtStart === token &&
        !path.includes("/auth/") &&
        path !== "/me/password" &&
        !(path === "/me" && options.method === "DELETE")
      )
        expired();
      throw new ApiError(
        response.status,
        data.error?.code || "request_failed",
        data.error?.message ||
          data.detail ||
          "Something went wrong. Please try again.",
        data.error?.request_id || response.headers.get("X-Request-ID"),
      );
    }
    return data as T;
  } catch (error) {
    if (error instanceof ApiError) throw error;
    throw new ApiError(
      0,
      "connection",
      "Vaachak may be waking up. Please try again in a moment, or check your connection. Your answer is still here.",
    );
  } finally {
    clearTimeout(timer);
  }
}
export const get = <T = any>(path: string) => request<T>(path);
export const send = <T = any>(path: string, body?: unknown, method = "POST") =>
  request<T>(path, {
    method,
    ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
  });
/** Complete generated operation registry; routes and verbs are checked against backend OpenAPI. */
export function operation<T = any>(
  name: keyof typeof operations,
  parameters: Record<string, string | number> = {},
  body?: unknown,
) {
  const op = operations[name];
  const path = op.path
    .replace(/\{([^}]+)\}/g, (_, key) => {
      if (parameters[key] === undefined)
        throw new Error(`Missing route parameter ${key}`);
      return encodeURIComponent(parameters[key]);
    })
    .replace(/^\/api/, "");
  return request<T>(path, {
    method: op.method,
    ...(body !== undefined
      ? { body: body instanceof FormData ? body : JSON.stringify(body) }
      : {}),
  });
}
