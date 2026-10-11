import { beforeEach, expect, it, vi } from "vitest";
const state = vi.hoisted(() => ({ exists: true, size: 12 }));
vi.mock("expo-blob", () => ({ Blob: globalThis.Blob }));
vi.mock("expo-file-system", () => ({
  File: class {
    exists = state.exists;
    size = state.size;
    type = "audio/mpeg";
    async bytes() { return new Uint8Array([0, 0, 0, 24, 102, 116, 121, 112, 109, 112, 52, 50]); }
  },
}));
import { appendNativeRecording } from "../src/features/nativeRecordingUpload";
beforeEach(() => { state.exists = true; state.size = 12; });
it("uploads actual bytes with MP4 MIME despite Android's MPEG classification", async () => {
  const form = new FormData();
  await appendNativeRecording(form, "file:///practice.m4a", "audio");
  const audio = form.get("audio") as File;
  expect(audio.name).toBe("practice.m4a");
  expect(audio.type).toBe("audio/mp4");
  expect(audio.size).toBe(12);
  expect(new Uint8Array(await audio.arrayBuffer()).slice(4, 8)).toEqual(new Uint8Array([102, 116, 121, 112]));
});
it.each(["missing", "empty"])("rejects a %s recording before upload", async (kind) => {
  if (kind === "missing") state.exists = false;
  else state.size = 0;
  await expect(appendNativeRecording(new FormData(), "file:///practice.m4a", "audio"))
    .rejects.toThrow("Please record again");
});
