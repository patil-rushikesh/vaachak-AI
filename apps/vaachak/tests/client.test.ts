import { beforeEach, describe, it, expect, vi } from "vitest";
vi.mock("react-native", () => ({ Platform: { OS: "web" } }));
import {
  request,
  send,
  setSession,
  ApiError,
  operation,
} from "../src/api/client";
describe("API reliability and session boundaries", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
    setSession(null);
  });
  it("adds bearer auth without putting credentials in URLs", async () => {
    const fetcher = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValue(new Response(JSON.stringify({ id: 1 })));
    setSession("test-token");
    await request("/me");
    expect(fetcher.mock.calls[0][0]).toBe("/api/me");
    expect(fetcher.mock.calls[0][1]?.headers).toMatchObject({
      Authorization: "Bearer test-token",
    });
  });
  it("lets the runtime set multipart boundaries", async () => {
    const fetcher = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValue(new Response("{}"));
    const form = new FormData();
    form.append("transcript", "hello");
    await request("/attempts", { method: "POST", body: form });
    expect(fetcher.mock.calls[0][1]?.headers).not.toHaveProperty(
      "Content-Type",
    );
  });
  it("keeps safe server messages and request IDs", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({
          error: {
            code: "history_exists",
            message: "Archive this lesson instead.",
            request_id: "request-123",
          },
        }),
        { status: 409 },
      ),
    );
    await expect(send("/lessons/1", undefined, "DELETE")).rejects.toMatchObject(
      {
        status: 409,
        code: "history_exists",
        message: "Archive this lesson instead.",
        requestId: "request-123",
      },
    );
  });
  it("expires the authenticated session on unauthorized reads", async () => {
    const expired = vi.fn();
    setSession("test", expired);
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response("{}", { status: 401 }),
    );
    await request("/me").catch(() => {});
    expect(expired).toHaveBeenCalledOnce();
  });
  it("does not log out on an incorrect current password", async () => {
    const expired = vi.fn();
    setSession("test", expired);
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response("{}", { status: 401 }),
    );
    await send("/me/password", {}).catch(() => {});
    expect(expired).not.toHaveBeenCalled();
  });
  it("turns connectivity errors into recoverable UX copy", async () => {
    vi.spyOn(globalThis, "fetch").mockRejectedValue(
      new TypeError("Failed to fetch"),
    );
    await expect(request("/attempts")).rejects.toMatchObject({
      status: 0,
      code: "connection",
    });
  });
  it("never retries a mutation automatically", async () => {
    const f = vi
      .spyOn(globalThis, "fetch")
      .mockRejectedValue(new TypeError("network"));
    await send("/attempts", {}).catch(() => {});
    expect(f).toHaveBeenCalledOnce();
  });
});
