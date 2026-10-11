import React, { useState } from "react";
import { send } from "../api/client";
import { Button, Label, Row, ErrorBox } from "./ui";
export function FeedbackRating({ attemptId }: { attemptId: number }) {
  const [saved, setSaved] = useState(false),
    [busy, setBusy] = useState(false),
    [error, setError] = useState<unknown>();
  async function rate(helpful: boolean) {
    setBusy(true);
    setError(null);
    try {
      await send("/feedback-reports", {
        category: "feedback",
        attempt_id: attemptId,
        helpful,
      });
      setSaved(true);
    } catch (e) {
      setError(e);
    } finally {
      setBusy(false);
    }
  }
  return (
    <>
      <ErrorBox error={error} />
      {saved ? (
        <Label muted>
          Thank you. Your feedback helps improve the next activity.
        </Label>
      ) : (
        <>
          <Label muted>Was this correction useful?</Label>
          <Row>
            <Button
              title="Yes, useful"
              kind="quiet"
              disabled={busy}
              onPress={() => rate(true)}
            />
            <Button
              title="Needs improvement"
              kind="quiet"
              disabled={busy}
              onPress={() => rate(false)}
            />
          </Row>
        </>
      )}
    </>
  );
}
