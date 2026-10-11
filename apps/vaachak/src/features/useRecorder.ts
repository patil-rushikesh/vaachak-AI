import {
  useAudioRecorder,
  useAudioRecorderState,
  RecordingPresets,
  AudioModule,
  setAudioModeAsync,
} from "expo-audio";
import { useEffect, useState, useRef } from "react";
import { AppState } from "react-native";
import { File } from "expo-file-system";
import { appendNativeRecording } from "./nativeRecordingUpload";
export function useRecorder() {
  const recorder = useAudioRecorder(RecordingPresets.HIGH_QUALITY);
  const state = useAudioRecorderState(recorder);
  const [uri, setUri] = useState<string | null>(null);
  const lastUri = useRef<string | null>(null);
  const remove = (path: string | null) => {
    if (path) {
      try {
        const file = new File(path);
        if (file.exists) file.delete();
      } catch {
        /* cache cleanup is best effort */
      }
    }
  };
  async function stop() {
    await recorder.stop();
    lastUri.current = recorder.uri;
    setUri(recorder.uri);
    await setAudioModeAsync({
      allowsRecording: false,
      playsInSilentMode: true,
    });
  }
  useEffect(() => {
    const listener = AppState.addEventListener("change", (next) => {
      if (next !== "active" && recorder.isRecording)
        void stop().catch(() => {});
    });
    return () => {
      listener.remove();
      try {
        if (recorder.isRecording)
          void recorder
            .stop()
            .then(() => remove(lastUri.current))
            .catch(() => {});
        else remove(lastUri.current);
      } catch {
        remove(lastUri.current);
      }
    };
  }, []);
  return {
    uri,
    recording: state.isRecording,
    duration: state.durationMillis,
    async start() {
      const p = await AudioModule.requestRecordingPermissionsAsync();
      if (!p.granted)
        throw new Error(
          "Microphone access is off. Enable it in device settings, or use typed practice.",
        );
      await setAudioModeAsync({
        allowsRecording: true,
        playsInSilentMode: true,
      });
      remove(uri);
      setUri(null);
      await recorder.prepareToRecordAsync();
      recorder.record();
    },
    stop,
    clear() {
      remove(uri);
      setUri(null);
    },
    async append(form: FormData, field = "audio") {
      if (!uri) throw new Error("Record your answer first.");
      await appendNativeRecording(form, uri, field);
    },
  };
}
