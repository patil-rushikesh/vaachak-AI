import { Blob } from "expo-blob";
import { File } from "expo-file-system";

export async function appendNativeRecording(form: FormData, uri: string, field: string) {
  const file = new File(uri);
  if (!file.exists || file.size === 0)
    throw new Error("Your recording is no longer available. Please record again.");
  // HIGH_QUALITY uses an MP4 container. Some Android devices mislabel .m4a
  // as audio/mpeg; explicit MIME and filename keep strict server validation valid.
  const audio = Object.assign(
    new Blob([await file.bytes()], { type: "audio/mp4" }),
    { name: "practice.m4a" },
  );
  // Expo Blob uses ArrayBufferLike in its typings; expo/fetch accepts its bytes().
  form.append(field, audio as unknown as globalThis.Blob, "practice.m4a");
}
