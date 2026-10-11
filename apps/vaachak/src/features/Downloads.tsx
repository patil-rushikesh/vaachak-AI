import React, { useEffect, useState } from "react";
import AsyncStorage from "@react-native-async-storage/async-storage";
import { get } from "../api/client";
import { Button, Card, Label, Title, ErrorBox } from "../components/ui";
const key = "vaachak.public-practice.v1";
export async function clearDownloads() {
  await AsyncStorage.removeItem(key);
}
export function Downloads({ canDownload = true }: { canDownload?: boolean }) {
  const [pack, setPack] = useState<any>(),
    [index, setIndex] = useState(0),
    [choice, setChoice] = useState<number>(),
    [error, setError] = useState<unknown>(),
    [busy, setBusy] = useState(false);
  useEffect(() => {
    AsyncStorage.getItem(key)
      .then((raw) => {
        if (raw) {
          const p = JSON.parse(raw);
          if (Date.parse(p.expires_at) > Date.now()) setPack(p);
          else void clearDownloads();
        }
      })
      .catch(setError);
  }, []);
  async function download() {
    setBusy(true);
    setError(null);
    try {
      const p = await get("/practice-download");
      await AsyncStorage.setItem(key, JSON.stringify(p));
      setPack(p);
      setIndex(0);
      setChoice(undefined);
    } catch (e) {
      setError(e);
    } finally {
      setBusy(false);
    }
  }
  const item = pack?.items[index];
  return (
    <Card>
      <Title small>Practice for a quiet connection</Title>
      <Label muted>
        Download up to 30 public text activities. No microphone, AI or private
        classroom content. Available for seven days; scores here are
        self-practice only.
      </Label>
      <ErrorBox error={error} />
      {canDownload && (
        <Button
          title={
            pack ? "Refresh practice download" : "Download public practice"
          }
          disabled={busy}
          kind="secondary"
          onPress={download}
        />
      )}
      {item ? (
        <>
          <Label>
            {index + 1}/{pack.items.length} · {item.prompt}
          </Label>
          {item.options.map((o: string, i: number) => (
            <Button
              key={o}
              title={o}
              kind="quiet"
              disabled={choice !== undefined}
              onPress={() => setChoice(i)}
            />
          ))}
          {choice !== undefined && (
            <>
              <Label>
                {choice === item.correct
                  ? "That’s right."
                  : `Try this: ${item.options[item.correct]}`}
              </Label>
              <Label muted>
                {item.explain || "Notice how the words fit the sentence."}
              </Label>
              <Button
                title="Next offline activity"
                onPress={() => {
                  setIndex((index + 1) % pack.items.length);
                  setChoice(undefined);
                }}
              />
            </>
          )}
          <Button
            title="Remove download"
            kind="quiet"
            onPress={() => {
              clearDownloads()
                .then(() => setPack(undefined))
                .catch(setError);
            }}
          />
        </>
      ) : (
        <Label muted>No saved practice available yet.</Label>
      )}
    </Card>
  );
}
