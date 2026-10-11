import { Downloads } from "./src/features/Downloads";
import React from "react";
import { Pressable, Text, View, useWindowDimensions } from "react-native";
import { Stack, router, usePathname } from "expo-router";
import { Header, getHeaderTitle } from "expo-router/react-navigation";
import { SafeAreaProvider, SafeAreaView } from "react-native-safe-area-context";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { StatusBar } from "expo-status-bar";
import Ionicons from "@expo/vector-icons/Ionicons";
import { AuthProvider, useAuth } from "./src/providers/Auth";
import { AuthScreen } from "./src/features/AuthScreen";
import {
  Button,
  Card,
  Label,
  Loading,
  Title,
  ErrorBox,
} from "./src/components/ui";
import { colors as c } from "./src/theme";
const client = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 30000,
      retry: (count, error: any) =>
        count < 1 && (error.status === 0 || error.status >= 500),
      refetchOnWindowFocus: false,
    },
    mutations: { retry: false },
  },
});

class Boundary extends React.Component<
  { children: React.ReactNode },
  { failed: boolean }
> {
  state = { failed: false };
  static getDerivedStateFromError() {
    return { failed: true };
  }
  render() {
    return this.state.failed ? (
      <SafeAreaView
        style={{
          flex: 1,
          justifyContent: "center",
          padding: 30,
          backgroundColor: c.bg,
        }}
      >
        <Card>
          <Title small>Let’s take a fresh breath.</Title>
          <Label>A screen couldn’t load. Your saved practice is safe.</Label>
          <Button
            title="Reload this screen"
            onPress={() => {
              client.clear();
              this.setState({ failed: false });
            }}
          />
        </Card>
      </SafeAreaView>
    ) : (
      this.props.children
    );
  }
}
function Shell() {
  const { user, loading, startupError, initialize } = useAuth();
  const wide = useWindowDimensions().width >= 1000;
  const active = usePathname().split("/")[1] || "Today";
  if (loading) return <Loading />;
  if (startupError)
    return (
      <View style={{ padding: 24 }}>
        <ErrorBox error={startupError} retry={initialize} />
        <Downloads canDownload={false} />
      </View>
    );
  if (!user) return <AuthScreen />;
  const teacher = user.role === "teacher";
  const tabs = teacher
    ? [
        ["Today", "Today", "sunny-outline"],
        ["Classes", "Classes", "people-outline"],
        ["Library", "Library", "library-outline"],
      ]
    : [
        ["Today", "Today", "sunny-outline"],
        ["Practice", "Practice", "compass-outline"],
        ["Classes", "Class", "people-outline"],
        ["Progress", "Progress", "bar-chart-outline"],
      ];
  const nav = (name: string) => {
    router.navigate(name === "Today" ? "/" : (`/${name}` as any));
  };
  const menu = (
    <>
      {tabs.map(([name, title, icon]) => (
        <Pressable
          accessibilityRole="tab"
          accessibilityState={{ selected: active === name }}
          accessibilityLabel={title}
          key={name}
          onPress={() => nav(name)}
          style={{
            flexDirection: wide ? "row" : "column",
            alignItems: "center",
            gap: wide ? 14 : 3,
            padding: wide ? 17 : 10,
            minHeight: 54,
            borderRadius: 16,
            backgroundColor: active === name ? c.soft : "transparent",
            flex: wide ? undefined : 1,
          }}
        >
          <Ionicons
            name={icon as any}
            size={24}
            color={active === name ? c.green : c.muted}
          />
          <Text
            style={{
              fontSize: wide ? 16 : 11,
              fontWeight: "700",
              color: active === name ? c.green : c.muted,
            }}
          >
            {title}
          </Text>
        </Pressable>
      ))}
    </>
  );
  return (
    <View
      style={{
        flex: 1,
        flexDirection: wide ? "row" : "column",
        backgroundColor: c.bg,
      }}
    >
      {wide && (
        <View
          style={{
            width: 232,
            padding: 24,
            gap: 16,
            borderRightWidth: 1,
            borderColor: c.line,
            backgroundColor: c.paper,
          }}
        >
          <View
            style={{
              flexDirection: "row",
              alignItems: "center",
              gap: 10,
              marginBottom: 34,
              marginTop: 12,
            }}
          >
            <Ionicons name="chatbubble-ellipses" size={30} color={c.green} />
            <Title small>vaachak</Title>
          </View>
          {menu}
          <View style={{ flex: 1 }} />
          {!teacher && (
            <Button
              title="My review"
              kind="secondary"
              onPress={() => nav("Review")}
            />
          )}
          <Button
            title={teacher ? "Saved work" : "My learning goals"}
            kind="secondary"
            onPress={() => nav("Growth")}
          />
          <Button
            title="My account"
            kind="quiet"
            icon="person-circle-outline"
            onPress={() => nav("Settings")}
          />
          <Label muted style={{ fontSize: 11 }}>
            A little practice. A lot of possibility.
          </Label>
        </View>
      )}
      <View style={{ flex: 1 }}>
        <View
          style={{
            height: 60,
            paddingHorizontal: 24,
            flexDirection: "row",
            alignItems: "center",
            justifyContent: "space-between",
            borderBottomWidth: 1,
            borderColor: c.line,
            backgroundColor: c.paper,
          }}
        >
          <Text style={{ fontWeight: "800", fontSize: 18, color: c.ink }}>
            {wide
              ? teacher
                ? "Teacher studio"
                : "Your learning space"
              : "vaachak"}
          </Text>
          <Pressable
            accessibilityRole="button"
            accessibilityLabel="Open my account"
            onPress={() => nav("Settings")}
            style={{
              backgroundColor: c.lime,
              width: 38,
              height: 38,
              borderRadius: 14,
              alignItems: "center",
              justifyContent: "center",
            }}
          >
            <Text style={{ fontWeight: "800", color: c.ink }}>
              {user.name.charAt(0).toUpperCase()}
            </Text>
          </Pressable>
        </View>
        <Stack
          screenOptions={{
            // Safe-area padding belongs to the outer shell, not this nested page header.
            header: ({ options, route, back }) => (
              <Header
                back={back}
                title={getHeaderTitle(options, route.name)}
                headerStatusBarHeight={0}
                headerTintColor={c.green}
                headerShadowVisible={false}
              />
            ),
            headerShadowVisible: false,
            headerTintColor: c.green,
            contentStyle: { backgroundColor: c.bg },
          }}
        >
          <Stack.Screen name="index" options={{ headerShown: false }} />
          <Stack.Screen
            name="[page]"
            options={{
              title: active === "Knowledge" ? "Teaching notes" : active,
              headerBackTitle: "Back",
            }}
          />
        </Stack>
        {!wide && (
          <View
            style={{
              flexDirection: "row",
              backgroundColor: c.paper,
              borderTopWidth: 1,
              borderColor: c.line,
              paddingHorizontal: 6,
            }}
          >
            {menu}
          </View>
        )}
      </View>
    </View>
  );
}
export default function App() {
  return (
    <SafeAreaProvider>
      <SafeAreaView style={{ flex: 1, backgroundColor: c.bg }}>
        <StatusBar style="dark" />
        <QueryClientProvider client={client}>
          <AuthProvider>
            <Boundary>
              <Shell />
            </Boundary>
          </AuthProvider>
        </QueryClientProvider>
      </SafeAreaView>
    </SafeAreaProvider>
  );
}
