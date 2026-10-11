import { useEffect, useRef, useState } from "react";
export function encodeWav(samples: Float32Array, sampleRate: number) {
  const buffer = new ArrayBuffer(44 + samples.length * 2),
    v = new DataView(buffer);
  const text = (offset: number, s: string) => {
    for (let i = 0; i < s.length; i++) v.setUint8(offset + i, s.charCodeAt(i));
  };
  text(0, "RIFF");
  v.setUint32(4, 36 + samples.length * 2, true);
  text(8, "WAVE");
  text(12, "fmt ");
  v.setUint32(16, 16, true);
  v.setUint16(20, 1, true);
  v.setUint16(22, 1, true);
  v.setUint32(24, sampleRate, true);
  v.setUint32(28, sampleRate * 2, true);
  v.setUint16(32, 2, true);
  v.setUint16(34, 16, true);
  text(36, "data");
  v.setUint32(40, samples.length * 2, true);
  samples.forEach((s, i) =>
    v.setInt16(44 + i * 2, Math.max(-1, Math.min(1, s)) * 32767, true),
  );
  return new Blob([buffer], { type: "audio/wav" });
}
export function useRecorder() {
  const [uri, setUri] = useState<string | null>(null),
    [recording, setRecording] = useState(false),
    [duration, setDuration] = useState(0);
  const active = useRef<MediaRecorder | null>(null),
    stream = useRef<MediaStream | null>(null),
    blob = useRef<Blob | null>(null),
    timer = useRef<any>(null),
    url = useRef<string | null>(null);
  const clear = () => {
    if (url.current) URL.revokeObjectURL(url.current);
    url.current = null;
    blob.current = null;
    setUri(null);
  };
  useEffect(
    () => () => {
      active.current?.state === "recording" && active.current.stop();
      stream.current?.getTracks().forEach((t) => t.stop());
      clearInterval(timer.current);
      if (url.current) URL.revokeObjectURL(url.current);
    },
    [],
  );
  return {
    uri,
    recording,
    duration,
    clear,
    async start() {
      if (!navigator.mediaDevices?.getUserMedia)
        throw new Error(
          "Recording needs HTTPS or localhost. You can use typed practice here.",
        );
      clear();
      try {
        stream.current = await navigator.mediaDevices.getUserMedia({
          audio: true,
        });
      } catch {
        throw new Error(
          "Microphone access is off. Allow it in browser settings or choose typed practice.",
        );
      }
      const rec = new MediaRecorder(stream.current);
      active.current = rec;
      const chunks: Blob[] = [];
      rec.ondataavailable = (e) => {
        if (e.data.size) chunks.push(e.data);
      };
      (rec as any).chunks = chunks;
      rec.start();
      setRecording(true);
      setDuration(0);
      const start = Date.now();
      timer.current = setInterval(() => setDuration(Date.now() - start), 250);
    },
    async stop() {
      const rec = active.current;
      if (!rec) return;
      await new Promise<void>((resolve) => {
        rec.onstop = () => resolve();
        rec.stop();
      });
      clearInterval(timer.current);
      stream.current?.getTracks().forEach((t) => t.stop());
      setRecording(false);
      const encoded = new Blob((rec as any).chunks, { type: rec.mimeType });
      const ctx = new AudioContext();
      try {
        const audio = await ctx.decodeAudioData(await encoded.arrayBuffer());
        const samples = new Float32Array(audio.length);
        for (let c = 0; c < audio.numberOfChannels; c++) {
          const channel = audio.getChannelData(c);
          for (let i = 0; i < samples.length; i++)
            samples[i] += channel[i] / audio.numberOfChannels;
        }
        blob.current = encodeWav(samples, audio.sampleRate);
        url.current = URL.createObjectURL(blob.current);
        setUri(url.current);
      } finally {
        await ctx.close();
      }
    },
    async append(form: FormData, field = "audio") {
      if (!blob.current) throw new Error("Record your answer first.");
      if (blob.current.size > 8 * 1024 * 1024)
        throw new Error(
          "That recording is too long. Please try a shorter answer.",
        );
      form.append(field, blob.current, "practice.wav");
    },
  };
}
