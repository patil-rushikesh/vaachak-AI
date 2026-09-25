const KEY = "vachak.session";
let current = null;
try {
  current = JSON.parse(sessionStorage.getItem(KEY) || "null");
} catch {
  sessionStorage.removeItem(KEY);
}

export const session = () => current;
export function saveSession(value) {
  current = value;
  if (value) sessionStorage.setItem(KEY, JSON.stringify(value));
  else sessionStorage.removeItem(KEY);
}

export class ApiError extends Error {
  constructor(message, status) {
    super(message);
    this.status = status;
  }
}

export async function api(path, options = {}) {
  const { body, method = "GET", ...other } = options;
  const headers = new Headers(options.headers || {});
  const requestToken = current?.access_token;
  if (requestToken) headers.set("Authorization", `Bearer ${requestToken}`);
  let data = body;
  if (body !== undefined && !(body instanceof FormData)) {
    headers.set("Content-Type", "application/json");
    data = JSON.stringify(body);
  }
  let response;
  try {
    response = await fetch(path, {
      ...other,
      method,
      headers,
      body: data,
      cache: "no-store",
    });
  } catch (error) {
    if (error.name === "AbortError") throw error;
    throw new ApiError(
      "Cannot reach the server. Check your connection, then try again.",
      0,
    );
  }
  if (!response.ok) {
    let message = `Request failed (${response.status}). Please try again.`;
    try {
      const result = await response.json();
      if (typeof result.detail === "string") message = result.detail;
      else if (Array.isArray(result.detail))
        message = result.detail
          .map(
            (item) =>
              `${(item.loc || []).filter((v) => v !== "body").join(" ")}: ${item.msg}`,
          )
          .join("; ");
    } catch {
      /* Keep readable HTTP fallback. */
    }
    if (
      response.status === 401 &&
      requestToken &&
      current?.access_token === requestToken &&
      !path.startsWith("/auth/")
    )
      window.dispatchEvent(new CustomEvent("session-expired"));
    throw new ApiError(message, response.status);
  }
  if (response.status === 204) return null;
  if (options.blob) return response.blob();
  return response.json();
}
