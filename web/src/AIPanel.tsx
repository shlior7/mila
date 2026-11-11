import { useEffect, useRef, useState, type ReactNode } from "react";
import Markdown from "react-markdown";
import { api, type ChatMessage, type Recording } from "./api";
import { ANALYZE_PROMPT, listModels, loadSettings, saveSettings, streamReply, type AISettings, type Provider } from "./ai";

type Props = { recording: Recording; onSaved: (r: Recording) => void; onError: (e: unknown) => void; onSeek: (t: number) => void };

export default function AIPanel({ recording, onSaved, onError, onSeek }: Props) {
  const [settings, setSettings] = useState<AISettings>(loadSettings);
  const [showSettings, setShowSettings] = useState(() => !loadSettings().keys[loadSettings().provider]);
  const [tab, setTab] = useState<"analysis" | "chat">("analysis");
  const [chat, setChat] = useState<ChatMessage[]>(recording.chat ?? []);
  const [draft, setDraft] = useState("");
  const [streaming, setStreaming] = useState<string | null>(null);
  const [kind, setKind] = useState<"analysis" | "chat">("analysis");
  const [error, setError] = useState("");
  const abort = useRef<AbortController | null>(null);
  const bottom = useRef<HTMLDivElement>(null);

  useEffect(() => { bottom.current?.scrollIntoView({ block: "end" }); }, [chat, streaming]);
  useEffect(() => () => abort.current?.abort(), []);

  const model = settings.models[settings.provider];
  const run = async (what: "analysis" | "chat", messages: ChatMessage[], save: (reply: string) => Partial<Recording>) => {
    setError("");
    setKind(what);
    setStreaming("");
    abort.current = new AbortController();
    let fields: Partial<Recording>;
    try {
      fields = save(await streamReply({ settings, recording, messages, onText: setStreaming, signal: abort.current.signal }));
    } catch (err) {
      if ((err as Error).name !== "AbortError") setError((err as Error).message);
      setStreaming(null);
      return;
    }
    // Show the reply now and save behind it, so the next question isn't
    // blocked on the round trip to the server.
    onSaved({ ...recording, ...fields });
    setStreaming(null);
    try { onSaved(await api.patch(recording.id, fields)); } catch (err) { onError(err); }
  };

  const analyze = () => run("analysis", [{ role: "user", content: ANALYZE_PROMPT }], (markdown) => ({
    analysis: { markdown, model, at: new Date().toISOString() },
  }));

  const ask = (question: string) => {
    const next: ChatMessage[] = [...chat, { role: "user", content: question }];
    setChat(next);
    setDraft("");
    setTab("chat");
    run("chat", next, (reply) => {
      const saved: ChatMessage[] = [...next, { role: "assistant", content: reply }];
      setChat(saved);
      return { chat: saved };
    });
  };

  return (
    <aside className="ai">
      <header>
        <div className="tabs">
          <button className={tab === "analysis" ? "on" : ""} onClick={() => setTab("analysis")}>Analysis</button>
          <button className={tab === "chat" ? "on" : ""} onClick={() => setTab("chat")}>Chat</button>
        </div>
        <button className="link small" onClick={() => setShowSettings((v) => !v)}>
          {settings.provider === "anthropic" ? "Claude" : "OpenAI"} · {model || "no model"} ⚙
        </button>
      </header>
      {showSettings && <Settings settings={settings} onChange={(s) => { setSettings(s); saveSettings(s); }} onDone={() => setShowSettings(false)} />}
      {error && <p className="error">{error}</p>}

      <div className="ai-body">
        {tab === "analysis" ? (
          streaming !== null && kind === "analysis" ? <Reply text={streaming || "…"} onSeek={onSeek} />
            : recording.analysis ? (
              <>
                <Reply text={recording.analysis.markdown} onSeek={onSeek} />
                <p className="muted small">By {recording.analysis.model}. <button className="link" onClick={analyze}>Redo</button></p>
              </>
            ) : (
              <div className="empty-ai">
                <p className="muted">A summary, key points, action items and topics, with timestamps.</p>
                <button className="primary" onClick={analyze}>Analyze</button>
              </div>
            )
        ) : (
          <>
            {chat.map((m, i) => (
              <div key={i} className={`bubble ${m.role}`}>
                {m.role === "assistant" ? <Reply text={m.content} onSeek={onSeek} /> : <p dir="auto">{m.content}</p>}
              </div>
            ))}
            {streaming !== null && kind === "chat" && <div className="bubble assistant"><Reply text={streaming || "…"} onSeek={onSeek} /></div>}
            {!chat.length && !(streaming !== null && kind === "chat") && (
              <div className="suggestions">
                {["What were the main decisions?", "Who said they'd do what?", "Write a short follow-up email."].map((q) => (
                  <button key={q} onClick={() => ask(q)}>{q}</button>
                ))}
              </div>
            )}
            {chat.length > 0 && streaming === null && (
              <button className="link small" onClick={async () => {
                setChat([]);
                try { onSaved(await api.patch(recording.id, { chat: [] })); } catch (err) { onError(err); }
              }}>Clear chat</button>
            )}
          </>
        )}
        <div ref={bottom} />
      </div>

      <form className="ask" onSubmit={(e) => { e.preventDefault(); if (draft.trim() && streaming === null) ask(draft.trim()); }}>
        <textarea dir="auto" rows={2} placeholder="Ask about this recording…" value={draft}
          onChange={(e) => setDraft(e.target.value)}
          onKeyDown={(e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); e.currentTarget.form?.requestSubmit(); } }} />
        {streaming !== null
          ? <button type="button" onClick={() => abort.current?.abort()}>Stop</button>
          : <button className="primary" disabled={!draft.trim()}>Send</button>}
      </form>
    </aside>
  );
}

/** Markdown, with [12:34] timestamps turned into buttons that seek the player. */
function Reply({ text, onSeek }: { text: string; onSeek: (t: number) => void }) {
  const stamps = (children: ReactNode): ReactNode =>
    typeof children === "string"
      ? children.split(/(\[\d{1,2}:\d{2}(?::\d{2})?\])/).map((part, i) => {
          const m = part.match(/^\[(\d{1,2}):(\d{2})(?::(\d{2}))?\]$/);
          if (!m) return part;
          const [h, mm, ss] = m[3] ? [+m[1], +m[2], +m[3]] : [0, +m[1], +m[2]];
          return <button key={i} className="stamp" onClick={() => onSeek(h * 3600 + mm * 60 + ss)}>{part.slice(1, -1)}</button>;
        })
      : Array.isArray(children) ? children.map((c, i) => <span key={i}>{stamps(c)}</span>) : children;
  return (
    <div className="md" dir="auto">
      <Markdown components={{
        p: ({ children }) => <p>{stamps(children)}</p>,
        li: ({ children }) => <li>{stamps(children)}</li>,
      }}>{text}</Markdown>
    </div>
  );
}

function Settings({ settings, onChange, onDone }: { settings: AISettings; onChange: (s: AISettings) => void; onDone: () => void }) {
  const [models, setModels] = useState<string[]>([]);
  const [status, setStatus] = useState("");
  const provider = settings.provider;
  const key = settings.keys[provider];

  useEffect(() => {
    setModels([]);
    if (!key) return;
    let alive = true;
    setStatus("Checking the key…");
    listModels(provider, key).then(
      (ids) => {
        if (!alive) return;
        setModels(ids);
        setStatus("");
        if (!settings.models[provider] || !ids.includes(settings.models[provider])) {
          onChange({ ...settings, models: { ...settings.models, [provider]: ids[0] ?? "" } });
        }
      },
      (err) => alive && setStatus(`That key didn't work: ${(err as Error).message}`),
    );
    return () => { alive = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [provider, key]);

  const set = (p: Partial<AISettings>) => onChange({ ...settings, ...p });
  return (
    <div className="settings card">
      <label className="inline">Provider
        <select value={provider} onChange={(e) => set({ provider: e.target.value as Provider })}>
          <option value="anthropic">Claude (Anthropic)</option>
          <option value="openai">OpenAI</option>
        </select>
      </label>
      <label>API key
        <input type="password" autoComplete="off" placeholder={provider === "anthropic" ? "sk-ant-…" : "sk-…"} value={key}
          onChange={(e) => set({ keys: { ...settings.keys, [provider]: e.target.value.trim() } })} />
      </label>
      <label className="inline">Model
        <select value={settings.models[provider]} onChange={(e) => set({ models: { ...settings.models, [provider]: e.target.value } })}>
          {!models.includes(settings.models[provider]) && settings.models[provider] && <option>{settings.models[provider]}</option>}
          {models.map((m) => <option key={m}>{m}</option>)}
        </select>
      </label>
      {status && <p className="muted small">{status}</p>}
      <p className="muted small">The key is kept in this browser only and sent straight to {provider === "anthropic" ? "Anthropic" : "OpenAI"}; the Mila server never sees it. Usage is billed to your account.</p>
      <button onClick={onDone}>Done</button>
    </div>
  );
}
