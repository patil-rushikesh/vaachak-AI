import React, { useEffect, useState } from "react";
import { Platform, Switch } from "react-native";
import { File, Paths } from "expo-file-system";
import * as Sharing from "expo-sharing";
import { useAuth } from "../providers/Auth";
import { get, send } from "../api/client";
import { useData } from "./Learning";
import {
  Button,
  Card,
  Confirm,
  ErrorBox,
  Field,
  Label,
  Page,
  QueryState,
  Row,
  Title,
} from "../components/ui";
export function Settings({ navigation: n }: any) {
  const { user, logout, clear } = useAuth(),
    q = useData("/me/preferences");
  const [timezone, setTimezone] = useState(""),
    [consent, setConsent] = useState(false),
    [current, setCurrent] = useState(""),
    [password, setPassword] = useState(""),
    [deletion, setDeletion] = useState(""),
    [error, setError] = useState<any>(),
    [message, setMessage] = useState(""),
    [busy, setBusy] = useState(false);
  useEffect(() => {
    if (q.data) {
      setTimezone(q.data.timezone);
      setConsent(q.data.research_consent);
    }
  }, [q.data]);
  async function work(fn: () => Promise<void>) {
    setBusy(true);
    setError(null);
    setMessage("");
    try {
      await fn();
    } catch (e) {
      setError(e);
    } finally {
      setBusy(false);
    }
  }
  return (
    <Page>
      <Button
        title={
          user?.role === "teacher"
            ? "Saved drafts & archives"
            : "My goals & continuous practice"
        }
        kind="secondary"
        onPress={() => n.navigate("Growth")}
      />
      <Title>Your space. Your choices.</Title>
      <Card>
        <Title small>{user?.name}</Title>
        <Label muted>
          {user?.email} · {user?.role}
        </Label>
        <Button
          title="Sign out"
          kind="secondary"
          onPress={() => work(logout)}
          busy={busy}
        />
      </Card>
      <ErrorBox error={error} />
      {message && <Label>{message}</Label>}
      <QueryState query={q}>
        {() => (
          <Card>
            <Title small>Make progress feel local</Title>
            <Field
              label="Timezone"
              value={timezone}
              onChangeText={setTimezone}
              placeholder="Asia/Kolkata"
            />
            <Button
              title="Use device timezone"
              kind="quiet"
              onPress={() =>
                setTimezone(Intl.DateTimeFormat().resolvedOptions().timeZone)
              }
            />
            <Label muted>
              The interface and practice content are currently in English.
            </Label>
            <Row>
              <Switch
                accessibilityLabel="Optional research consent"
                value={consent}
                onValueChange={setConsent}
              />
              <Label style={{ flex: 1 }}>
                Allow participation in project research
              </Label>
            </Row>
            <Label muted>
              Optional. You can withdraw this preference at any time. Ask your
              instructor for study details before opting in.
            </Label>
            <Button
              title="Save preferences"
              busy={busy}
              onPress={() =>
                work(async () => {
                  await send(
                    "/me/preferences",
                    { timezone, language: "en", research_consent: consent },
                    "PATCH",
                  );
                  q.refetch();
                  setMessage("Your preferences are saved.");
                })
              }
            />
          </Card>
        )}
      </QueryState>
      <Card>
        <Title small>Keep your account secure</Title>
        <Field
          label="Current password"
          value={current}
          onChangeText={setCurrent}
          secure
        />
        <Field
          label="New password (at least 8 characters)"
          value={password}
          onChangeText={setPassword}
          secure
        />
        <Button
          title="Change password & sign out"
          kind="secondary"
          disabled={!current || password.length < 8}
          busy={busy}
          onPress={() =>
            work(async () => {
              await send("/me/password", {
                current_password: current,
                new_password: password,
              });
              await clear();
            })
          }
        />
      </Card>
      <Card>
        <Title small>Your learning data belongs to you</Title>
        <Label muted>
          Export your profile and practice evidence as JSON. Audio links require
          your authenticated account.
        </Label>
        <Button
          title="Export my data"
          kind="secondary"
          busy={busy}
          onPress={() =>
            work(async () => {
              const data = await get("/me/export");
              const contents = JSON.stringify(data, null, 2);
              if (Platform.OS === "web") {
                const url = URL.createObjectURL(
                  new Blob([contents], { type: "application/json" }),
                );
                const anchor = document.createElement("a");
                anchor.href = url;
                anchor.download = "vaachak-my-data.json";
                anchor.click();
                setTimeout(() => URL.revokeObjectURL(url), 1000);
              } else {
                const file = new File(Paths.cache, "vaachak-my-data.json");
                file.write(contents);
                try {
                  await Sharing.shareAsync(file.uri, {
                    mimeType: "application/json",
                  });
                } finally {
                  file.delete();
                }
              }
              setMessage("Your export is ready.");
            })
          }
        />
      </Card>
      <Card>
        <Title small>Delete account</Title>
        <Label muted>
          This permanently removes your account and personal practice records.
          Teachers must transfer owned classes and courses through the operator
          first.
        </Label>
        <Field
          label="Password to confirm deletion"
          value={deletion}
          onChangeText={setDeletion}
          secure
        />
        {deletion && (
          <Confirm
            title="Delete my account"
            label="Permanently delete"
            danger
            body="This cannot be undone. Export any data you want to keep before continuing."
            onConfirm={async () => {
              await send("/me", { password: deletion }, "DELETE");
              await clear();
            }}
          />
        )}
      </Card>
    </Page>
  );
}
