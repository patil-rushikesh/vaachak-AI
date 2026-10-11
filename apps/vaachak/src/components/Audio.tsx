import React, { useEffect, useState } from "react";
import { Platform } from "react-native";
import { useAudioPlayer, useAudioPlayerStatus } from "expo-audio";
import { API_URL, authHeaders } from "../api/client";
import { Button, ErrorBox } from "./ui";
export function Audio({ path, uri }: { path?: string; uri?: string }) {
  const [source, setSource] = useState<any>(uri || null),
    [error, setError] = useState<any>();
  const player = useAudioPlayer(source);
  const state = useAudioPlayerStatus(player);
  useEffect(() => {
    if (!path) {
      setSource(uri || null);
      return;
    }
    let url: string | undefined;
    let alive = true;
    if (Platform.OS === "web") {
      fetch(`${API_URL}/api${path}`, { headers: authHeaders() as HeadersInit })
        .then(async (r) => {
          if (!r.ok)
            throw new Error(
              "This recording is unavailable or you no longer have access.",
            );
          url = URL.createObjectURL(await r.blob());
          if (alive) setSource(url);
          else URL.revokeObjectURL(url);
        })
        .catch((e) => alive && setError(e));
    } else setSource({ uri: `${API_URL}/api${path}`, headers: authHeaders() });
    return () => {
      alive = false;
      if (url) URL.revokeObjectURL(url);
    };
  }, [path, uri]);
  return (
    <>
      <ErrorBox error={error} />
      <Button
        title={state.playing ? "Pause recording" : "Play recording"}
        kind="secondary"
        icon={state.playing ? "pause" : "play"}
        disabled={!source}
        onPress={() => {
          try {
            if (state.playing) player.pause();
            else {
              if (state.didJustFinish) void player.seekTo(0);
              player.play();
            }
          } catch (e) {
            setError(e);
          }
        }}
      />
    </>
  );
}
