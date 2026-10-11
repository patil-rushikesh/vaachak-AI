import { stopReminder } from "../features/reminders";
import { clearDownloads } from "../features/Downloads";
import React, { createContext, useContext, useEffect, useState } from "react";
import { Platform } from "react-native";
import * as SecureStore from "expo-secure-store";
import { useQueryClient } from "@tanstack/react-query";
import { get, send, setSession, ApiError } from "../api/client";
import { User } from "../api/types";
const Context = createContext<any>(null);
// Web sessions are tab-memory only. Native credentials live in the OS keychain.
export function AuthProvider({ children }: { children: React.ReactNode }) {
  const [user, setUser] = useState<User | null>(null),
    [loading, setLoading] = useState(true),
    [startupError, setStartupError] = useState<unknown>();
  const cache = useQueryClient();
  async function clear() {
    await Promise.allSettled([stopReminder(), clearDownloads()]);
    setStartupError(undefined);
    setSession(null);
    setUser(null);
    cache.clear();
    if (Platform.OS !== "web")
      await SecureStore.deleteItemAsync("vaachak.session");
  }
  async function initialize() {
    setLoading(true);
    setStartupError(undefined);
    try {
      const t =
        Platform.OS === "web"
          ? null
          : await SecureStore.getItemAsync("vaachak.session");
      setSession(t, () => {
        void clear();
      });
      if (t) setUser(await get("/me"));
    } catch (e) {
      if (e instanceof ApiError && e.status === 401) await clear();
      else setStartupError(e);
    } finally {
      setLoading(false);
    }
  }
  useEffect(() => {
    void initialize();
  }, []);
  async function authenticate(mode: string, body: any) {
    const data = await send(`/auth/${mode}`, body);
    if (Platform.OS !== "web")
      await SecureStore.setItemAsync("vaachak.session", data.token);
    setSession(data.token, () => {
      void clear();
    });
    cache.clear();
    setUser(data.user);
  }
  async function logout() {
    try {
      await send("/auth/logout");
    } finally {
      await clear();
    }
  }
  return (
    <Context.Provider
      value={{
        user,
        loading,
        startupError,
        initialize,
        authenticate,
        logout,
        clear,
      }}
    >
      {children}
    </Context.Provider>
  );
}
export const useAuth = () =>
  useContext(Context) as {
    user: User | null;
    loading: boolean;
    startupError: unknown;
    initialize: () => Promise<void>;
    authenticate: (mode: string, body: any) => Promise<void>;
    logout: () => Promise<void>;
    clear: () => Promise<void>;
  };
