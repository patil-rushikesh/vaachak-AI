import React, { ReactNode, useState } from "react";
import {
  ActivityIndicator,
  KeyboardAvoidingView,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
  RefreshControl,
  Modal,
  useWindowDimensions,
} from "react-native";
import Ionicons from "@expo/vector-icons/Ionicons";
import { colors as c } from "../theme";
export function Label({
  children,
  muted = false,
  style,
}: {
  children: ReactNode;
  muted?: boolean;
  style?: any;
}) {
  return (
    <Text style={[s.text, muted && { color: c.muted }, style]}>{children}</Text>
  );
}
export function Title({
  children,
  small = false,
}: {
  children: ReactNode;
  small?: boolean;
}) {
  return (
    <Text
      accessibilityRole="header"
      style={[s.title, small && { fontSize: 24 }]}
    >
      {children}
    </Text>
  );
}
export function Row({ children, style }: { children: ReactNode; style?: any }) {
  return <View style={[s.row, style]}>{children}</View>;
}
export function Card({
  children,
  style,
  onPress,
}: {
  children: ReactNode;
  style?: any;
  onPress?: () => void;
}) {
  return onPress ? (
    <Pressable
      accessibilityRole="button"
      onPress={onPress}
      style={({ pressed }) => [s.card, style, pressed && { opacity: 0.8 }]}
    >
      {children}
    </Pressable>
  ) : (
    <View style={[s.card, style]}>{children}</View>
  );
}
export function Button({
  title,
  onPress,
  kind = "primary",
  busy = false,
  disabled = false,
  icon,
}: {
  title: string;
  onPress: () => void;
  kind?: "primary" | "secondary" | "quiet" | "danger";
  busy?: boolean;
  disabled?: boolean;
  icon?: any;
}) {
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={title}
      accessibilityState={{ disabled: disabled || busy, busy }}
      disabled={disabled || busy}
      onPress={onPress}
      style={({ pressed }) => [
        s.button,
        kind === "secondary" && {
          backgroundColor: c.soft,
          borderBottomColor: c.line,
        },
        kind === "quiet" && {
          backgroundColor: "transparent",
          borderBottomWidth: 0,
        },
        kind === "danger" && {
          backgroundColor: c.red,
          borderBottomColor: "#822930",
        },
        (disabled || busy) && { opacity: 0.5 },
        pressed && { transform: [{ translateY: 2 }], borderBottomWidth: 1 },
      ]}
    >
      {busy ? (
        <ActivityIndicator color={kind === "primary" ? "white" : c.green} />
      ) : (
        <>
          {icon && (
            <Ionicons
              name={icon}
              size={20}
              color={kind === "primary" ? "white" : c.green}
            />
          )}
          <Text
            style={[
              s.buttonText,
              (kind === "secondary" || kind === "quiet") && { color: c.green },
            ]}
          >
            {title}
          </Text>
        </>
      )}
    </Pressable>
  );
}
export function Field({
  label,
  value,
  onChangeText,
  secure = false,
  multiline = false,
  placeholder = "",
  keyboardType = "default",
  disabled = false,
}: {
  label: string;
  value: string;
  onChangeText: (v: string) => void;
  secure?: boolean;
  multiline?: boolean;
  placeholder?: string;
  keyboardType?: any;
  disabled?: boolean;
}) {
  return (
    <View style={{ gap: 8 }}>
      <Label style={{ fontWeight: "600" }}>{label}</Label>
      <TextInput
        testID={`field-${label.toLowerCase().replace(/[^a-z0-9]+/g, "-")}`}
        accessibilityLabel={label}
        editable={!disabled}
        accessibilityState={{ disabled }}
        value={value}
        onChangeText={onChangeText}
        secureTextEntry={secure}
        multiline={multiline}
        placeholder={placeholder}
        placeholderTextColor={c.muted}
        keyboardType={keyboardType}
        autoCapitalize={
          secure || keyboardType === "email-address" ? "none" : "sentences"
        }
        style={[
          s.input,
          multiline && { minHeight: 100, textAlignVertical: "top" },
        ]}
      />
    </View>
  );
}
export function Pill({
  text,
  tone = "green",
}: {
  text: string;
  tone?: "green" | "orange" | "blue";
}) {
  return (
    <View
      style={{
        alignSelf: "flex-start",
        paddingHorizontal: 12,
        paddingVertical: 6,
        borderRadius: 30,
        backgroundColor:
          tone === "orange" ? c.peach : tone === "blue" ? c.blue : c.soft,
      }}
    >
      <Text
        style={{
          fontSize: 12,
          fontWeight: "700",
          color: tone === "orange" ? c.orange : c.green,
        }}
      >
        {text}
      </Text>
    </View>
  );
}
export function ErrorBox({ error, retry }: { error: any; retry?: () => void }) {
  if (!error) return null;
  return (
    <View
      accessibilityRole="alert"
      style={[s.card, { backgroundColor: c.redSoft, borderColor: "#F3D0CF" }]}
    >
      <Label style={{ color: c.red }}>{error.message || String(error)}</Label>
      {error.requestId && (
        <Label muted style={{ fontSize: 11 }}>
          Support reference: {error.requestId}
        </Label>
      )}
      {retry && <Button title="Try again" kind="secondary" onPress={retry} />}
    </View>
  );
}
export function Empty({
  title,
  body,
  action,
}: {
  title: string;
  body: string;
  action?: ReactNode;
}) {
  return (
    <Card style={{ alignItems: "center", padding: 32, gap: 14 }}>
      <Ionicons name="leaf-outline" size={36} color={c.green} />
      <Title small>{title}</Title>
      <Label muted style={{ textAlign: "center", maxWidth: 420 }}>
        {body}
      </Label>
      {action}
    </Card>
  );
}
export function Page({
  children,
  refresh,
  refreshing = false,
}: {
  children: ReactNode;
  refresh?: () => void;
  refreshing?: boolean;
}) {
  return (
    <KeyboardAvoidingView
      style={{ flex: 1 }}
      behavior={Platform.OS === "ios" ? "padding" : undefined}
    >
      <ScrollView
        style={{ flex: 1, backgroundColor: c.bg }}
        contentContainerStyle={s.page}
        keyboardShouldPersistTaps="handled"
        refreshControl={
          refresh ? (
            <RefreshControl
              refreshing={refreshing}
              onRefresh={refresh}
              tintColor={c.green}
            />
          ) : undefined
        }
      >
        <View
          style={{
            width: "100%",
            maxWidth: 1100,
            alignSelf: "center",
            gap: 22,
          }}
        >
          {children}
        </View>
      </ScrollView>
    </KeyboardAvoidingView>
  );
}
export function Loading() {
  return (
    <View style={{ padding: 60, alignItems: "center", gap: 16 }}>
      <ActivityIndicator color={c.green} />
      <Label muted>Getting things ready…</Label>
    </View>
  );
}
export function QueryState({
  query,
  children,
}: {
  query: any;
  children: (data: any) => ReactNode;
}) {
  if (query.isPending) return <Loading />;
  if (query.isError)
    return <ErrorBox error={query.error} retry={() => query.refetch()} />;
  return <>{children(query.data)}</>;
}
export function Confirm({
  title,
  body,
  onConfirm,
  label = "Confirm",
  danger = false,
}: {
  title: string;
  body: string;
  onConfirm: () => Promise<unknown>;
  label?: string;
  danger?: boolean;
}) {
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<any>();
  return (
    <>
      <Button
        title={title}
        kind={danger ? "danger" : "secondary"}
        onPress={() => setOpen(true)}
      />
      <Modal
        visible={open}
        transparent
        animationType="fade"
        onRequestClose={() => setOpen(false)}
      >
        <View style={s.overlay}>
          <Card style={{ width: "100%", maxWidth: 440 }}>
            <Title small>{title}</Title>
            <Label muted>{body}</Label>
            <ErrorBox error={error} />
            <Button
              title={label}
              kind={danger ? "danger" : "primary"}
              busy={busy}
              onPress={async () => {
                setBusy(true);
                try {
                  await onConfirm();
                  setOpen(false);
                } catch (e) {
                  setError(e);
                } finally {
                  setBusy(false);
                }
              }}
            />
            <Button
              title="Cancel"
              kind="quiet"
              disabled={busy}
              onPress={() => {
                setOpen(false);
                setError(null);
              }}
            />
          </Card>
        </View>
      </Modal>
    </>
  );
}
export function ProgressBar({ value }: { value: number }) {
  return (
    <View
      accessibilityRole="progressbar"
      accessibilityValue={{ min: 0, max: 100, now: Math.round(value) }}
      style={{
        height: 12,
        backgroundColor: c.line,
        borderRadius: 12,
        overflow: "hidden",
      }}
    >
      <View
        style={{
          width: `${Math.min(100, Math.max(0, value))}%`,
          height: "100%",
          backgroundColor: c.green,
          borderRadius: 12,
        }}
      />
    </View>
  );
}
export const s = StyleSheet.create({
  text: { fontSize: 16, lineHeight: 24, color: c.ink },
  title: {
    fontSize: 34,
    lineHeight: 40,
    fontWeight: "800",
    letterSpacing: -1,
    color: c.ink,
  },
  row: {
    flexDirection: "row",
    alignItems: "center",
    gap: 12,
    flexWrap: "wrap",
  },
  card: {
    backgroundColor: c.paper,
    borderRadius: 24,
    padding: 22,
    borderWidth: 1,
    borderColor: c.line,
    gap: 14,
  },
  button: {
    minHeight: 50,
    paddingHorizontal: 20,
    paddingVertical: 12,
    borderRadius: 16,
    backgroundColor: c.green,
    borderBottomWidth: 4,
    borderBottomColor: c.greenDark,
    alignItems: "center",
    justifyContent: "center",
    flexDirection: "row",
    gap: 8,
  },
  buttonText: {
    fontSize: 15,
    fontWeight: "700",
    color: "white",
    textAlign: "center",
  },
  input: {
    backgroundColor: c.paper,
    borderWidth: 1.5,
    borderColor: c.line,
    borderRadius: 14,
    padding: 15,
    fontSize: 16,
    color: c.ink,
    minHeight: 52,
  },
  page: { padding: 24, paddingBottom: 48 },
  overlay: {
    flex: 1,
    backgroundColor: "#19392E88",
    justifyContent: "center",
    alignItems: "center",
    padding: 24,
  },
});
