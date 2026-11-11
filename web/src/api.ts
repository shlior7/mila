// The Mila server (server/modal/api.py). VITE_API_URL is set at build time.
export const API = (import.meta.env.VITE_API_URL as string).replace(/\/$/, "");

export type Segment = { id: number; start: number; end: number; text: string };
export type ChatMessage = { role: "user" | "assistant"; content: string };
export type Analysis = { markdown: string; model: string; at: string };

export type Recording = {
  id: string;
  title: string;
  createdAt: string;
  status: "queued" | "downloading" | "transcribing" | "done" | "error";
  source: "upload" | "recording" | "url";
  language: string;
  url?: string;
  media?: string;
  mediaType?: "audio" | "video";
  duration?: number;
  error?: string;
  segments?: Segment[];
  text?: string;
  analysis?: Analysis;
  chat?: ChatMessage[];
};

const TOKEN = "mila.token";

export const session = {
  get token() {
    try { return localStorage.getItem(TOKEN); } catch { return null; }
  },
  set(token: string | null) {
    try { token ? localStorage.setItem(TOKEN, token) : localStorage.removeItem(TOKEN); } catch { /* private mode */ }
  },
};

export class SignedOut extends Error {}

async function call<T>(path: string, init: RequestInit = {}): Promise<T> {
  const headers = new Headers(init.headers);
  if (session.token) headers.set("Authorization", `Bearer ${session.token}`);
  if (init.body && !(init.body instanceof FormData)) headers.set("Content-Type", "application/json");
  const response = await fetch(API + path, { ...init, headers });
  if (response.status === 401 && path !== "/api/login") {
    session.set(null);
    throw new SignedOut("Sign in again.");
  }
  if (!response.ok) {
    let detail = response.statusText;
    try { detail = (await response.json()).detail ?? detail; } catch { /* not JSON */ }
    throw new Error(typeof detail === "string" ? detail : JSON.stringify(detail));
  }
  return response.json();
}

export const api = {
  login: (username: string, password: string) =>
    call<{ token: string; username: string }>("/api/login", { method: "POST", body: JSON.stringify({ username, password }) }),
  list: () => call<Recording[]>("/api/recordings"),
  get: (id: string) => call<Recording>(`/api/recordings/${id}`),
  upload: (file: File, language: string, source: "upload" | "recording") => {
    const form = new FormData();
    form.append("file", file);
    form.append("language", language);
    form.append("source", source);
    return call<Recording>("/api/recordings", { method: "POST", body: form });
  },
  link: (url: string, language: string) =>
    call<Recording>("/api/recordings/link", { method: "POST", body: JSON.stringify({ url, language }) }),
  patch: (id: string, fields: Partial<Pick<Recording, "title" | "analysis" | "chat">>) =>
    call<Recording>(`/api/recordings/${id}`, { method: "PATCH", body: JSON.stringify(fields) }),
  retry: (id: string) => call<Recording>(`/api/recordings/${id}/retry`, { method: "POST" }),
  remove: (id: string) => call<{ deleted: string }>(`/api/recordings/${id}`, { method: "DELETE" }),
  mediaURL: (id: string) => `${API}/api/recordings/${id}/media?token=${encodeURIComponent(session.token ?? "")}`,
};

export const working = (r: Recording) => r.status !== "done" && r.status !== "error";
