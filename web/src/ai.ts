// Chat and analysis, straight from the browser to Claude or OpenAI with
// the user's own key. The key stays in this browser (localStorage); the
// Mila server never sees it.
import Anthropic from "@anthropic-ai/sdk";
import OpenAI from "openai";
import type { ChatMessage, Recording } from "./api";
import { clock } from "./format";

export type Provider = "anthropic" | "openai";
export type AISettings = { provider: Provider; keys: Record<Provider, string>; models: Record<Provider, string> };

const KEY = "mila.ai";
const DEFAULTS: AISettings = {
  provider: "anthropic",
  keys: { anthropic: "", openai: "" },
  models: { anthropic: "claude-opus-5-5", openai: "" },
};

export function loadSettings(): AISettings {
  try {
    const saved = JSON.parse(localStorage.getItem(KEY) ?? "{}");
    return { ...DEFAULTS, ...saved, keys: { ...DEFAULTS.keys, ...saved.keys }, models: { ...DEFAULTS.models, ...saved.models } };
  } catch {
    return DEFAULTS;
  }
}

export function saveSettings(settings: AISettings) {
  try { localStorage.setItem(KEY, JSON.stringify(settings)); } catch { /* private mode */ }
}

export async function listModels(provider: Provider, apiKey: string): Promise<string[]> {
  if (provider === "anthropic") {
    const client = new Anthropic({ apiKey, dangerouslyAllowBrowser: true });
    const ids: string[] = [];
    for await (const model of client.models.list()) ids.push(model.id);
    return ids;
  }
  const client = new OpenAI({ apiKey, dangerouslyAllowBrowser: true });
  const models = [];
  for await (const model of client.models.list()) models.push(model);
  // Chat models only; newest first.
  return models
    .filter((m) => /^(gpt|o\d|chatgpt)/.test(m.id) && !/(audio|realtime|tts|transcribe|image|search)/.test(m.id))
    .sort((a, b) => b.created - a.created)
    .map((m) => m.id);
}

/** The transcript as the model sees it: one timestamped line per segment. */
export function transcriptForModel(recording: Recording): string {
  const lines = (recording.segments ?? []).map((s) => `[${clock(s.start)}] ${s.text.trim()}`);
  return lines.join("\n") || recording.text || "";
}

function systemPrompt(recording: Recording): string {
  return [
    "You help the user understand a recording they transcribed with Mila.",
    "Answer from the transcript below. When you point at a moment, cite its timestamp like [12:34].",
    "If the transcript doesn't say, say so rather than guessing.",
    "Reply in the language the user writes in; the transcript may be in Hebrew.",
    "",
    `Title: ${recording.title}`,
    recording.url ? `Source: ${recording.url}` : "",
    "",
    "<transcript>",
    transcriptForModel(recording),
    "</transcript>",
  ].join("\n");
}

export const ANALYZE_PROMPT = [
  "Analyze this recording. Use Markdown with these sections:",
  "## Summary — a few sentences.",
  "## Key points — bullets, each with a timestamp.",
  "## Action items — who does what, if anyone committed to anything; otherwise say there are none.",
  "## Topics — the main subjects, with where each starts.",
  "Write it in the transcript's language.",
].join("\n");

// Server-side refusal fallback: only these models accept `fallbacks: "default"`.
const FALLBACK_MODELS = /^claude-(opus-5|fable-5|sonnet-5-5)/;

export async function streamReply(options: {
  settings: AISettings;
  recording: Recording;
  messages: ChatMessage[];
  onText: (snapshot: string) => void;
  signal?: AbortSignal;
}): Promise<string> {
  const { settings, recording, messages, onText, signal } = options;
  const apiKey = settings.keys[settings.provider];
  const model = settings.models[settings.provider];
  if (!apiKey) throw new Error("Add your API key in AI settings.");
  if (!model) throw new Error("Pick a model in AI settings.");
  const system = systemPrompt(recording);

  if (settings.provider === "anthropic") {
    const client = new Anthropic({ apiKey, dangerouslyAllowBrowser: true });
    const fallback = FALLBACK_MODELS.test(model);
    const stream = client.beta.messages.stream(
      {
        model,
        max_tokens: 16000,
        // The transcript is the big, stable part: cache it across turns.
        system: [{ type: "text", text: system, cache_control: { type: "ephemeral" } }],
        messages,
        ...(fallback ? { betas: ["server-side-fallback-2026-07-01"], fallbacks: "default" as const } : {}),
      },
      { signal },
    );
    stream.on("text", (_delta, snapshot) => onText(snapshot));
    const final = await stream.finalMessage();
    if (final.stop_reason === "refusal") throw new Error("Claude declined to answer this one.");
    return final.content.flatMap((b) => (b.type === "text" ? [b.text] : [])).join("");
  }

  const client = new OpenAI({ apiKey, dangerouslyAllowBrowser: true });
  const stream = await client.chat.completions.create(
    { model, stream: true, messages: [{ role: "system", content: system }, ...messages] },
    { signal },
  );
  let text = "";
  for await (const chunk of stream) {
    text += chunk.choices[0]?.delta?.content ?? "";
    onText(text);
  }
  return text;
}
