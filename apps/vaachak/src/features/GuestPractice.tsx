import React, { useState } from "react";
import { Button, Card, Label, Title, Row } from "../components/ui";
const sample = [
  {
    prompt: "She ___ English every day.",
    options: ["practise", "practises"],
    answer: 1,
    why: "Use practises with she in the present simple.",
  },
  {
    prompt: "Choose a polite request.",
    options: ["Could you explain that again, please?", "Explain again now."],
    answer: 0,
    why: "Could you…please? makes your request polite and clear.",
  },
  {
    prompt: "I worked ___ this project with my team.",
    options: ["on", "at"],
    answer: 0,
    why: "We work on a project and work with a team.",
  },
];
export function GuestPractice({ close }: { close: () => void }) {
  const [index, setIndex] = useState(0),
    [choice, setChoice] = useState<number>();
  const item = sample[index];
  return (
    <Card>
      <Title small>A small win before you sign up</Title>
      <Label muted>
        No account or microphone needed. This sample stays on this screen.
      </Label>
      <Label>{item.prompt}</Label>
      {item.options.map((o, i) => (
        <Button
          key={o}
          title={o}
          kind="secondary"
          disabled={choice !== undefined}
          onPress={() => setChoice(i)}
        />
      ))}
      {choice !== undefined && (
        <>
          <Title small>
            {choice === item.answer ? "You got it." : "One useful correction."}
          </Title>
          <Label>{item.why}</Label>
          <Button
            title={
              index === sample.length - 1
                ? "Try the sample again"
                : "Next sample"
            }
            onPress={() => {
              setIndex((index + 1) % sample.length);
              setChoice(undefined);
            }}
          />
        </>
      )}
      <Row>
        <Button title="Continue to sign in" kind="quiet" onPress={close} />
      </Row>
    </Card>
  );
}
