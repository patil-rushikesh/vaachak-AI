import { api } from "./api.js?v=demo3";

export function createAudioScope() {
  const urls = new Set();
  const disposers = new Set();
  const media = new Set();
  let alive = true;
  const urlFor = (blob) => {
    const url = URL.createObjectURL(blob);
    urls.add(url);
    return url;
  };
  return {
    urlFor,
    track: (player) => media.add(player),
    add: (fn) => disposers.add(fn),
    async load(container) {
      const players = container.matches("[data-audio-url]")
        ? [container]
        : [...container.querySelectorAll("[data-audio-url]")];
      await Promise.all(
        players.map(async (wrap) => {
          if (
            wrap.dataset.audioState === "loading" ||
            wrap.dataset.audioState === "ready"
          )
            return;
          wrap.dataset.audioState = "loading";
          try {
            const blob = await api(wrap.dataset.audioUrl, { blob: true });
            if (!alive || !wrap.isConnected) return;
            const audio = document.createElement("audio");
            audio.controls = true;
            audio.preload = "metadata";
            audio.src = urlFor(blob);
            media.add(audio);
            audio.setAttribute(
              "aria-label",
              wrap.dataset.label || "Audio recording",
            );
            audio.addEventListener("play", () =>
              document.querySelectorAll("audio").forEach((other) => {
                if (other !== audio) other.pause();
              }),
            );
            wrap.replaceChildren(audio);
            wrap.dataset.audioState = "ready";
          } catch (error) {
            if (!alive || !wrap.isConnected) return;
            const note = document.createElement("span");
            note.className = "field-error";
            note.textContent = `Audio unavailable: ${error.message}`;
            const retry = document.createElement("button");
            retry.type = "button";
            retry.className = "text-button";
            retry.textContent = "Retry";
            wrap.dataset.audioState = "error";
            retry.onclick = () => this.load(wrap);
            wrap.replaceChildren(note, retry);
          }
        }),
      );
    },
    dispose() {
      alive = false;
      disposers.forEach((fn) => fn());
      media.forEach((audio) => {
        audio.pause();
        audio.removeAttribute("src");
        audio.load();
      });
      media.clear();
      urls.forEach((url) => URL.revokeObjectURL(url));
      urls.clear();
    },
  };
}

export function mountRecorder(container, scope, { onChange = () => {} } = {}) {
  let file = null,
    recorder = null,
    stream = null,
    timer = null,
    startedAt = 0;
  let destroyed = false,
    context = null,
    frame = null,
    recordingURL = null,
    stopping = false,
    starting = false;
  container.innerHTML = `<div class="recorder-top"><div class="record-indicator"></div><strong data-record-label>Your voice, clearly heard</strong><span class="record-time">00:00</span></div>
    <canvas class="wave-canvas" height="56" aria-label="Live microphone waveform"></canvas>
    <p class="recorder-hint">Read naturally in a quiet space. Recording stops just before 2 minutes.</p>
    <div class="button-row"><button type="button" class="button button-primary" data-record>Start recording</button><label class="button button-secondary upload-label">Upload audio<input type="file" accept="audio/*,.webm,.mp4,.m4a,.wav,.ogg,.mp3" data-file></label></div>
    <div class="recorder-preview" hidden></div><p class="field-error" data-record-error role="alert" hidden></p>
    <p class="micro-copy">Original audio is preserved. Pitch evidence is experimental and ungraded.</p>`;
  const btn = container.querySelector("[data-record]");
  const picker = container.querySelector("[data-file]");
  const preview = container.querySelector(".recorder-preview");
  const error = container.querySelector("[data-record-error]");
  const label = container.querySelector("[data-record-label]");
  const time = container.querySelector(".record-time");
  const canvas = container.querySelector("canvas");
  const canvasCtx = canvas.getContext("2d");
  const clock = (sec) =>
    `${String(Math.floor(sec / 60)).padStart(2, "0")}:${String(sec % 60).padStart(2, "0")}`;
  function drawIdle() {
    canvas.width = Math.max(container.clientWidth - 48, 200) * 2;
    canvasCtx.clearRect(0, 0, canvas.width, canvas.height);
    canvasCtx.strokeStyle = "#a9bab0";
    canvasCtx.lineWidth = 2;
    canvasCtx.beginPath();
    canvasCtx.moveTo(0, 28);
    canvasCtx.lineTo(canvas.width, 28);
    canvasCtx.stroke();
  }
  drawIdle();
  function releaseStream() {
    stream?.getTracks().forEach((track) => track.stop());
    stream = null;
    if (timer) clearInterval(timer);
    timer = null;
    if (frame) cancelAnimationFrame(frame);
    frame = null;
    if (context) {
      context.close().catch(() => {});
      context = null;
    }
  }
  function showError(message) {
    error.textContent = message;
    error.hidden = false;
  }
  function selectFile(nextFile) {
    if (nextFile.size > 20 * 1024 * 1024) {
      showError("Use an audio recording smaller than 20 MB.");
      return;
    }
    if (!nextFile.size) {
      showError("This recording is empty. Please record or upload again.");
      return;
    }
    error.hidden = true;
    file = nextFile;
    preview.querySelectorAll("audio").forEach((audio) => {
      audio.pause();
      audio.removeAttribute("src");
      audio.load();
    });
    if (recordingURL) URL.revokeObjectURL(recordingURL);
    recordingURL = scope.urlFor(file);
    const audio = document.createElement("audio");
    audio.controls = true;
    audio.src = recordingURL;
    audio.preload = "metadata";
    scope.track(audio);
    audio.addEventListener("play", () =>
      document.querySelectorAll("audio").forEach((other) => {
        if (other !== audio) other.pause();
      }),
    );
    const name = document.createElement("span");
    name.className = "micro-copy";
    name.textContent = `${file.name} · ${(file.size / 1024).toFixed(0)} KB`;
    preview.replaceChildren(audio, name);
    preview.hidden = false;
    label.textContent = "Recording ready";
    btn.textContent = "Record again";
    onChange(file);
  }
  function stopRecording() {
    if (stopping) return;
    stopping = true;
    btn.disabled = true;
    picker.disabled = true;
    btn.textContent = "Preparing recording…";
    if (recorder && recorder.state !== "inactive") recorder.stop();
    releaseStream();
    container.classList.remove("is-recording");
  }
  btn.addEventListener("click", async () => {
    if (recorder?.state === "recording") {
      stopRecording();
      return;
    }
    if (stopping || starting) return;
    error.hidden = true;
    if (!navigator.mediaDevices?.getUserMedia || !window.MediaRecorder) {
      showError(
        "Microphone recording needs localhost or HTTPS in a supported browser. You can upload an audio file instead.",
      );
      return;
    }
    document.querySelectorAll("audio").forEach((audio) => audio.pause());
    btn.disabled = true;
    starting = true;
    picker.disabled = true;
    try {
      stream = await navigator.mediaDevices.getUserMedia({
        audio: {
          echoCancellation: false,
          noiseSuppression: false,
          autoGainControl: false,
        },
        video: false,
      });
      if (destroyed) {
        releaseStream();
        return;
      }
      const mime = [
        "audio/webm;codecs=opus",
        "audio/mp4",
        "audio/ogg;codecs=opus",
        "audio/webm",
      ].find((type) => MediaRecorder.isTypeSupported(type));
      const activeRecorder = new MediaRecorder(
        stream,
        mime ? { mimeType: mime } : undefined,
      );
      recorder = activeRecorder;
      const chunks = [];
      startedAt = Date.now();
      activeRecorder.ondataavailable = (event) => {
        if (event.data.size) chunks.push(event.data);
      };
      activeRecorder.onstop = () => {
        releaseStream();
        stopping = false;
        starting = false;
        if (destroyed) return;
        const type = activeRecorder.mimeType || "audio/webm";
        const ext = type.includes("mp4")
          ? "m4a"
          : type.includes("ogg")
            ? "ogg"
            : "webm";
        selectFile(new File(chunks, `voice-${Date.now()}.${ext}`, { type }));
        btn.disabled = false;
        picker.disabled = false;
        container.classList.remove("is-recording");
        drawIdle();
      };
      activeRecorder.onerror = () => {
        showError(
          "The microphone stopped unexpectedly. Try recording again or upload a file.",
        );
        stopRecording();
      };
      activeRecorder.start(250);
      picker.disabled = true;
      btn.textContent = "Stop recording";
      label.textContent = "Recording…";
      container.classList.add("is-recording");
      timer = setInterval(() => {
        const sec = Math.floor((Date.now() - startedAt) / 1000);
        time.textContent = clock(sec);
        if (sec >= 119) stopRecording();
      }, 250);
      const AudioContext = window.AudioContext || window.webkitAudioContext;
      if (AudioContext) {
        try {
          context = new AudioContext();
          const analyser = context.createAnalyser();
          analyser.fftSize = 1024;
          context.createMediaStreamSource(stream).connect(analyser);
          const data = new Uint8Array(analyser.frequencyBinCount);
          const draw = () => {
            analyser.getByteTimeDomainData(data);
            canvasCtx.clearRect(0, 0, canvas.width, canvas.height);
            canvasCtx.strokeStyle = "#225f48";
            canvasCtx.lineWidth = 2;
            canvasCtx.beginPath();
            data.forEach((v, i) => {
              const x = (i / data.length) * canvas.width;
              const y = (v / 255) * canvas.height;
              i ? canvasCtx.lineTo(x, y) : canvasCtx.moveTo(x, y);
            });
            canvasCtx.stroke();
            frame = requestAnimationFrame(draw);
          };
          draw();
        } catch {
          /* Recording remains available without visualization. */
        }
      }
    } catch (err) {
      releaseStream();
      showError(
        err.name === "NotAllowedError"
          ? "Microphone access was declined. Allow it in your browser or upload an audio file."
          : "No microphone is available. Check your device or upload an audio file.",
      );
    } finally {
      starting = false;
      if (!stopping) btn.disabled = false;
      if (recorder?.state !== "recording" && !stopping) picker.disabled = false;
    }
  });
  picker.addEventListener("change", () => {
    if (picker.files[0]) selectFile(picker.files[0]);
    picker.value = "";
  });
  const dispose = () => {
    destroyed = true;
    if (recorder?.state === "recording") recorder.stop();
    releaseStream();
  };
  scope.add(dispose);
  return {
    get file() {
      return file;
    },
    get isRecording() {
      return starting || stopping || recorder?.state === "recording";
    },
    dispose,
  };
}
