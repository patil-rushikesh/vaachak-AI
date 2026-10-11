import React, { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { useAuth } from "../providers/Auth";
import { readPending, clearPending } from "../api/pending";
import { get, ApiError } from "../api/client";
import { Button, Card, ErrorBox, Label, Title } from "./ui";
export function PendingSubmissions({ navigation }: any) {
  const { user } = useAuth();
  const q = useQuery({
    queryKey: ["pending", user?.id],
    queryFn: () => readPending(user!.id),
    staleTime: 0,
  });
  const [error, setError] = useState<any>(),
    [busy, setBusy] = useState(false);
  if (!q.data?.length) return null;
  return (
    <Card>
      <Title small>Let’s check your last answer.</Title>
      <Label>
        A submission was interrupted. Check what the server saved before trying
        it again.
      </Label>
      <ErrorBox error={error} />
      <Button
        title="Recover pending practice"
        busy={busy}
        onPress={async () => {
          const id = q.data![0];
          setBusy(true);
          setError(null);
          try {
            const state = await get(`/me/submissions/${id}`);
            if (state.status === "completed") {
              await clearPending(user!.id, id);
              q.refetch();
              navigation.navigate("Attempt", { id: state.attempt_id });
            } else if (state.status === "processing")
              setError(
                new Error(
                  "Your answer is still being checked. Try again in a moment.",
                ),
              );
            else {
              await clearPending(user!.id, id);
              q.refetch();
            }
          } catch (e) {
            if (e instanceof ApiError && e.status === 404) {
              await clearPending(user!.id, id);
              q.refetch();
            } else setError(e);
          } finally {
            setBusy(false);
          }
        }}
      />
    </Card>
  );
}
