import { Platform } from "react-native";
import * as SecureStore from "expo-secure-store";
const key = (userId: number) => `vaachak.pending.${userId}`;
// Retain opaque submission identities only, never answer text or audio.
export async function readPending(userId: number): Promise<string[]> {
  const raw =
    Platform.OS === "web"
      ? sessionStorage.getItem(key(userId))
      : await SecureStore.getItemAsync(key(userId));
  try {
    return raw ? JSON.parse(raw) : [];
  } catch {
    return [];
  }
}
async function write(userId: number, ids: string[]) {
  const data = JSON.stringify(ids);
  if (Platform.OS === "web") sessionStorage.setItem(key(userId), data);
  else await SecureStore.setItemAsync(key(userId), data);
}
export async function savePending(userId: number, id: string) {
  const ids = await readPending(userId);
  if (!ids.includes(id)) await write(userId, [...ids, id]);
}
export async function clearPending(userId: number, id: string) {
  await write(
    userId,
    (await readPending(userId)).filter((v) => v !== id),
  );
}
