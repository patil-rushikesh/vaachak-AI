import { Platform } from "react-native";
import Constants from "expo-constants";
export async function stopReminder() {
  if (Constants.executionEnvironment === "storeClient") return;
  const Notifications = await import("expo-notifications");
  await Notifications.cancelScheduledNotificationAsync("vaachak.practice");
}
export async function setReminder(hour: number) {
  if (Constants.executionEnvironment === "storeClient")
    throw new Error(
      "Reminders require an installed development or release build; Expo Go does not support this configuration.",
    );
  const Notifications = await import("expo-notifications");
  if (!Number.isInteger(hour) || hour < 7 || hour > 21)
    throw new Error("Choose an hour from 07 to 21.");
  if (Platform.OS === "android")
    await Notifications.setNotificationChannelAsync("practice", {
      name: "Optional practice reminders",
      importance: Notifications.AndroidImportance.DEFAULT,
    });
  const p = await Notifications.requestPermissionsAsync();
  if (!p.granted)
    throw new Error(
      "Notifications are off. You can still practise whenever you like.",
    );
  await stopReminder();
  await Notifications.scheduleNotificationAsync({
    identifier: "vaachak.practice",
    content: {
      title: "A little time for English?",
      body: "Your next small step is ready whenever you are.",
      sound: false,
    },
    trigger: {
      type: Notifications.SchedulableTriggerInputTypes.DAILY,
      hour,
      minute: 0,
      channelId: "practice",
    },
  });
}
