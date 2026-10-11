import { it, expect } from "vitest";
import { encodeWav } from "../src/features/useRecorder.web";
it("encodes bounded mono PCM with a valid RIFF duration header", async () => {
  const blob = encodeWav(new Float32Array([0, 1, -1, 0.5]), 16000);
  const buffer = await blob.arrayBuffer(),
    v = new DataView(buffer);
  expect(blob.type).toBe("audio/wav");
  expect(buffer.byteLength).toBe(52);
  expect(new TextDecoder().decode(buffer.slice(0, 4))).toBe("RIFF");
  expect(v.getUint32(24, true)).toBe(16000);
  expect(v.getUint32(40, true)).toBe(8);
  expect(v.getInt16(46, true)).toBe(32767);
  expect(v.getInt16(48, true)).toBe(-32767);
});
