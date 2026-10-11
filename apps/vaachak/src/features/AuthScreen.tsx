import { GuestPractice } from "./GuestPractice";
import React, { useState } from "react";
import { View, useWindowDimensions } from "react-native";
import Ionicons from "@expo/vector-icons/Ionicons";
import { useAuth } from "../providers/Auth";
import { send } from "../api/client";
import {
  Button,
  Card,
  ErrorBox,
  Field,
  Label,
  Page,
  Pill,
  Row,
  Title,
} from "../components/ui";
import { colors as c } from "../theme";
export function AuthScreen() {
  const { authenticate } = useAuth();
  const [mode, setMode] = useState("login"),
    [name, setName] = useState(""),
    [email, setEmail] = useState(""),
    [password, setPassword] = useState(""),
    [role, setRole] = useState("learner"),
    [invite, setInvite] = useState(""),
    [reset, setReset] = useState(""),
    [error, setError] = useState<any>(),
    [busy, setBusy] = useState(false),
    [message, setMessage] = useState("");
  const [sample, setSample] = useState(false);
  const wide = useWindowDimensions().width > 820;
  async function submit() {
    setBusy(true);
    setError(null);
    try {
      if (mode === "reset") {
        await send("/auth/reset-password", {
          token: reset,
          new_password: password,
        });
        setMode("login");
        setMessage("Password reset. You can sign in now.");
      } else
        await authenticate(mode, {
          name,
          email: email.trim(),
          password,
          role,
          ...(invite ? { teacher_invite: invite } : {}),
        });
    } catch (e) {
      setError(e);
    } finally {
      setBusy(false);
    }
  }
  return (
    <Page>
      {sample ? (
        <GuestPractice close={() => setSample(false)} />
      ) : (
        <Button
          title="Try a free 2-minute sample"
          kind="quiet"
          onPress={() => setSample(true)}
        />
      )}
      {mode === "reset" && (
        <Card>
          <Field
            label="Recovery email"
            value={email}
            onChangeText={setEmail}
            keyboardType="email-address"
          />
          <Button
            title="Email me reset instructions"
            disabled={busy || !email.trim()}
            onPress={async () => {
              setBusy(true);
              setError(null);
              try {
                const r = await send("/auth/password-reset-request", {
                  email: email.trim(),
                });
                setMessage(r.message);
              } catch (e) {
                setError(e);
              } finally {
                setBusy(false);
              }
            }}
          />
        </Card>
      )}
      <Row>
        <View
          style={{ backgroundColor: c.green, borderRadius: 15, padding: 11 }}
        >
          <Ionicons name="chatbubble-ellipses" size={25} color="white" />
        </View>
        <Title small>
          vaachak
          <TextDot />
        </Title>
        {wide && <Pill text="A little practice. A lot of possibility." />}
      </Row>
      <View
        style={{
          flexDirection: wide ? "row" : "column",
          gap: wide ? 48 : 20,
          paddingTop: wide ? 65 : 24,
          alignItems: "center",
        }}
      >
        {wide && (
          <View style={{ flex: 1, gap: 24, width: "100%" }}>
            <Pill text="YOUR VOICE, GROWING EVERY DAY" />
            <Title>Small steps.{"\n"}More confident English.</Title>
            <Label
              muted
              style={{ fontSize: 19, lineHeight: 30, maxWidth: 470 }}
            >
              Practise in everyday moments. Get one useful correction. Come back
              stronger.
            </Label>
            <View
              style={{
                backgroundColor: c.lime,
                borderRadius: 40,
                padding: 32,
                alignItems: "center",
                gap: 18,
                width: "100%",
                maxWidth: 460,
                transform: [{ rotate: "-2deg" }],
              }}
            >
              <Row>
                <View
                  style={{
                    width: 92,
                    height: 92,
                    borderRadius: 32,
                    backgroundColor: c.green,
                    alignItems: "center",
                    justifyContent: "center",
                  }}
                >
                  <Ionicons name="mic" size={48} color="white" />
                </View>
                <View style={{ gap: 10 }}>
                  <Pill text="Hello, possibilities!" />
                  <Label style={{ fontWeight: "800" }}>
                    Your next chapter starts{"\n"}with a conversation.
                  </Label>
                </View>
              </Row>
              <Row>
                <Pill text="Speak" />
                <Pill text="Discover" />
                <Pill text="Grow" />
              </Row>
            </View>
            <Label muted>
              No leaderboards. Just your progress, at your pace.
            </Label>
          </View>
        )}
        <Card style={{ width: "100%", maxWidth: 430, padding: 30 }}>
          <Title small>
            {mode === "login"
              ? "Welcome back"
              : mode === "reset"
                ? "A fresh start"
                : "Let’s get you started"}
          </Title>
          <Label muted>
            {mode === "login"
              ? "Your next small win is waiting."
              : mode === "reset"
                ? "Ask your instructor or operator for a single-use reset token."
                : "Create your personal learning space."}
          </Label>
          {mode === "register" && (
            <>
              <Field label="Your name" value={name} onChangeText={setName} />
              <Row>
                {["learner", "student", "teacher"].map((r) => (
                  <Button
                    key={r}
                    title={
                      r === "student"
                        ? "Class learner"
                        : r === "teacher"
                          ? "Teacher"
                          : "Independent"
                    }
                    kind={role === r ? "primary" : "secondary"}
                    onPress={() => setRole(r)}
                  />
                ))}
              </Row>
            </>
          )}
          {mode === "reset" ? (
            <Field label="Reset token" value={reset} onChangeText={setReset} />
          ) : (
            <Field
              label="Email"
              value={email}
              onChangeText={setEmail}
              keyboardType="email-address"
            />
          )}
          <Field
            label={mode === "reset" ? "New password" : "Password"}
            value={password}
            onChangeText={setPassword}
            secure
          />
          {mode === "register" && role === "teacher" && (
            <Field
              label="Teacher invite (if required)"
              value={invite}
              onChangeText={setInvite}
              secure
            />
          )}
          {message && <Label>{message}</Label>}
          <ErrorBox error={error} />
          <Button
            title={
              mode === "login"
                ? "Let’s practise"
                : mode === "reset"
                  ? "Reset password"
                  : "Create account"
            }
            busy={busy}
            disabled={
              password.length < (mode === "login" ? 1 : 8) ||
              (mode !== "reset" && !email.trim()) ||
              (mode === "register" && !name.trim())
            }
            onPress={submit}
          />
          <Button
            title={
              mode === "login"
                ? "New here? Create an account"
                : "Already learning? Sign in"
            }
            kind="quiet"
            onPress={() => {
              setMode(mode === "login" ? "register" : "login");
              setError(null);
            }}
          />
          {mode === "login" && (
            <Button
              title="Forgot password?"
              kind="quiet"
              onPress={() => setMode("reset")}
            />
          )}
          <Label muted style={{ fontSize: 12 }}>
            Designed for adult learners. Your practice and recordings stay
            private to you and authorized instructors.
          </Label>
        </Card>
      </View>
    </Page>
  );
}
function TextDot() {
  return <Label style={{ color: c.green }}>●</Label>;
}
